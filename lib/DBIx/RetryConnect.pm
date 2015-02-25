package DBIx::RetryConnect;

=head1 NAME

DBIx::RetryConnect - automatically retry DBI connect() with exponential backoff

=head1 SYNOPSIS

    use DBIx::RetryConnect qw(Pg);    # use default settings for all Pg connections

    use DBIx::RetryConnect Pg => sub { {} }; # same as above

    use DBIx::RetryConnect Pg => sub {   # set these options for all Pg connections
        return { total_delay => 300, verbose => 1, ... }
    };

    use DBIx::RetryConnect Pg => sub { # set options dynamically for Pg connections
        my ($drh, $dsn, $user, $password, $attrib) = @_;
        return undef if ... # don't do retry for this connection
        return { ... retry options to use ... };
    };

=head1 DESCRIPTION

The DBIx::RetryConnect module arranges for failed DBI connection attempts to be
automatically and transparently retried for a period of time, with a growing
delay between each retry.

As far as the application is concerned there's no change in behaviour.
Either the connection succeeds at once, succeeds sometime later after one or
more retries, or fails after one or more retries. It isn't aware of the retries.

The DBIx::RetryConnect module works by loading and I<monkey patching> the connect
method of the specified driver module. This allows it to work cleanly 'under the
covers' and thus avoid dealing with the complexities of C<connect_cached>,
C<dbi_connect_method>, C<RaiseError> etc. etc.

=head2 Multiple Usage

When DBIx::RetryConnect is used to configure a driver, the configuration is
added to a list of configurations for that driver.

When a connection fails for that driver the list of configuration code refs is
checked to find the first code ref that returns a hash reference. That hash is
then used to configure the retry behaviour for that connection retry.

=head2 Randomization

Wherever the documentation talks about the duration of a delay the I<actual>
delay is a random value between 50% and 100% of this value. This randomization
helps avoid a "thundering herd" where many systems might attempt to reconnect
at the same time.

=head2 Options

=head3 total_delay

The total time in seconds to spend retrying the connection before giving up
(default 30 seconds).

This time is an approximation. The actual time spent may overshoot by at least
the value of L</max_delay>, plus whatever time the connection attempts themselves
may take.

=head3 start_delay

The duration in seconds of the initial delay after the initial connection
attempt failed (default 0.1).

=head3 backoff_factor

For each subsequent attempt while retrying a connection the delay duration,
which started with L</start_delay>, is multiplied by L</backoff_factor>.

The default is 3. Use the value 2 if you want a strict exponential backoff,
but 3 seems to work better in general, i.e. fewer connection attempts.
See also L</max_delay>.

=head3 max_delay

The maximum duration, in seconds, for any individual retry delay. The default
is the value of L</total_delay> divided by 4. See also L</backoff_factor>.

=head3 verbose

Enable extra logging.

 1 - log each use of DBIx::RetryConnect module
 2 - also log each connect failure
 3 - also log each connect retry
 4 - also log each connect retry with more timing details

The default is the value of the C<DBIX_RETRYCONNECT_VERBOSE> environment
variable if set, else 0.

=cut


use strict;
use warnings;

use Carp qw(carp croak);
use DBI;

# proxy

my %installed_dbd_configs; # Pg => [ {...}, ... ]


sub import {
    my($exporter, @imports)  = @_;

    croak "No drivers specified"
        unless @imports;

        # default is ok if all previous are default
        # hash is ok if no previous
        # sub is ok if no previous hash or default
 
    while (my $dbd = shift @imports) {
        my $options = (@imports && ref $imports[0]) ? shift @imports : sub { {} };

        croak "$exporter $dbd argument must be a CODE reference, not $options"
            if defined($options) && ref $options ne 'CODE';

        if ($ENV{DBIX_RETRYCONNECT_VERBOSE}) {
            my $desc = (defined $options) ? "$options" : "default";
            carp "$exporter installing $desc config for $dbd";
        }

        my $configs = $installed_dbd_configs{$dbd} ||= [];
        push @$configs, $options; # add to list of configs for this DBD

        # install the retry hook for this DBD if this is the first config
        install_retry_connect($dbd, $configs) if @$configs == 1;
    }

    return;
}


sub install_retry_connect {
    my ($dbd, $configs) = @_;

    DBI->install_driver($dbd);

    my $connect_method = "DBD::${dbd}::dr::connect";

    my $orig_connect_subref = do { no strict 'refs'; *$connect_method{CODE} }
        or croak "$connect_method not defined";

    my $retry_state_class = "DBIx::RetryConnect::RetryState";

    my $retry_connect_subref = sub {

        my $retry;
        while (1) {

            my $dbh = $orig_connect_subref->(@_);
            return $dbh if $dbh;

            $retry ||= do {
                my $options = pick_retry_options_from_configs($configs, \@_);
                return undef if not $options;
                $retry_state_class->new($options, \@_);
            };

            $retry->pause
                or return undef;
        }
    };

    do {
        no warnings 'redefine';
        no strict 'refs';
        *$connect_method = $retry_connect_subref;
    };

    return;
}


sub pick_retry_options_from_configs {
    my ($configs, $connect_args) = @_;

    for my $config (@$configs) {
        my $dynamic_config = $config->(@$connect_args);
        return $dynamic_config if $dynamic_config;
    }

    return undef; # no config matched, so no retry behaviour
}


=head2 Multiple Usage

Currently DBIx::RetryConnect should only be used once per driver per application.
Subsequent usage will generate a warning. This may change.

=cut

{
package DBIx::RetryConnect::RetryState;

use Carp qw(carp croak);
use Time::HiRes qw(usleep);
use Hash::Util qw(lock_keys);

sub new {
    my ($class, $options, $connect_args) = @_;

    my $self = bless {
        total_delay => 30,
        next_delay => undef,
        max_delay => undef,
        backoff_factor => 3, # 1, 3, 9, 27
        verbose => $ENV{DBIX_RETRYCONNECT_VERBOSE} || 0,
        connect_args => $connect_args,
    } => $class;
    lock_keys(%$self);

    $self->{next_delay} = delete($options->{start_delay}) || 0.1;

    $self->{$_} = $options->{$_} for keys %$options;

    # calculated defaults
    $self->{max_delay} ||= ($self->{total_delay} / 4);

    if ($self->{verbose} >= 2) {
        my @ca = @{$self->{connect_args}};
        local $self->{connect_args} = "$ca[0]->{Name}:$ca[1]"; # just the driver and dsn, hide password
        my $kv = DBI::_concat_hash_sorted($self, "=", ", ", 1, undef);
        carp "DBIx::RetryConnect::RetryState $kv";
    }

    return $self;
}

sub calculate_next_delay {
    my $self = shift;

    return 0 if $self->{total_delay} <= 0;

    if ($self->{next_delay} > $self->{max_delay}) {
        $self->{next_delay} = $self->{max_delay};
    }

    # treat half the delay time as fixed and half as random
    # this helps avoid a thundering-herd problem
    my $this_delay = ($self->{next_delay} / 2) + rand($self->{next_delay} / 2);

    if ($self->{verbose} >= 3) {

        my $extra = "";
        $extra = sprintf " [delay %.1fs, remaining %.1fs]",
                $self->{next_delay}, $self->{total_delay}
            if $self->{verbose} >= 4;

        # fudge %Carp::Internal so the carp shows a more useful caller
        local $Carp::Internal{'DBI'} = 1;
        local $Carp::Internal{'DBIx::RetryConnect'} = 1;
        my ($drh, $dsn) = @{$self->{connect_args}};
        carp sprintf "DBIx::RetryConnect(%s:%s): sleeping for %.2gs after error: %s%s",
                $drh->{Name}, $dsn, $this_delay, $drh->errstr, $extra;
    }

    $self->{total_delay} -= $this_delay;     # track actual remaining time
    $self->{next_delay}  *= $self->{backoff_factor}; # backoff

    return $this_delay;
}

sub pause {
    my $self = shift;

    my $this_delay = $self->calculate_next_delay;

    return 0 if not $this_delay;

    usleep($this_delay * 1_000_000); # microseconds

    return 1;
}

} # end of DBIx::RetryConnect::RetryState

1;