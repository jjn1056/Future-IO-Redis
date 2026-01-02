package Future::IO::Redis;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use Future;
use Future::AsyncAwait;
use Future::IO 0.17;  # Need read/write methods
use Socket qw(pack_sockaddr_in inet_aton AF_INET SOCK_STREAM);
use IO::Socket::INET;
use Time::HiRes qw(time);

# Error classes
use Future::IO::Redis::Error::Connection;
use Future::IO::Redis::Error::Timeout;
use Future::IO::Redis::Error::Disconnected;
use Future::IO::Redis::Error::Redis;

# Import auto-generated command methods
use Future::IO::Redis::Commands;
our @ISA = qw(Future::IO::Redis::Commands);

# Try XS version first, fall back to pure Perl
BEGIN {
    eval { require Protocol::Redis::XS; 1 }
        or require Protocol::Redis;
}

sub _parser_class {
    return $INC{'Protocol/Redis/XS.pm'} ? 'Protocol::Redis::XS' : 'Protocol::Redis';
}

sub _calculate_backoff {
    my ($self, $attempt) = @_;

    # Exponential: delay * 2^(attempt-1)
    my $delay = $self->{reconnect_delay} * (2 ** ($attempt - 1));

    # Cap at max
    $delay = $self->{reconnect_delay_max} if $delay > $self->{reconnect_delay_max};

    # Apply jitter: delay * (1 +/- jitter)
    if ($self->{reconnect_jitter} > 0) {
        my $jitter_range = $delay * $self->{reconnect_jitter};
        my $jitter = (rand(2) - 1) * $jitter_range;
        $delay += $jitter;
    }

    return $delay;
}

sub new {
    my ($class, %args) = @_;

    # Parse URI if provided
    if ($args{uri}) {
        require Future::IO::Redis::URI;
        my $uri = Future::IO::Redis::URI->parse($args{uri});
        if ($uri) {
            my %uri_args = $uri->to_hash;
            # URI values are defaults, explicit args override
            %args = (%uri_args, %args);
            delete $args{uri};  # don't store the string
        }
    }

    my $self = bless {
        host     => $args{host} // 'localhost',
        port     => $args{port} // 6379,
        socket   => undef,
        parser   => undef,
        connected => 0,
        subscribing => 0,
        _read_buffer => '',

        # Timeout settings
        connect_timeout         => $args{connect_timeout} // 10,
        read_timeout            => $args{read_timeout} // 30,
        write_timeout           => $args{write_timeout} // 30,
        request_timeout         => $args{request_timeout} // 5,
        blocking_timeout_buffer => $args{blocking_timeout_buffer} // 2,

        # Inflight tracking with deadlines
        inflight => [],

        # Reconnection settings
        reconnect           => $args{reconnect} // 0,
        reconnect_delay     => $args{reconnect_delay} // 0.1,
        reconnect_delay_max => $args{reconnect_delay_max} // 60,
        reconnect_jitter    => $args{reconnect_jitter} // 0.25,
        queue_size          => $args{queue_size} // 1000,
        _reconnect_attempt  => 0,
        _command_queue      => [],

        # Callbacks
        on_connect    => $args{on_connect},
        on_disconnect => $args{on_disconnect},
        on_error      => $args{on_error},

        # Authentication
        password    => $args{password},
        username    => $args{username},
        database    => $args{database} // 0,
        client_name => $args{client_name},

        # TLS (will implement fully in Task 6)
        tls => $args{tls},
    }, $class;

    return $self;
}

# Connect to Redis server
async sub connect {
    my ($self) = @_;

    return $self if $self->{connected};

    # Create socket
    my $socket = IO::Socket::INET->new(
        Proto    => 'tcp',
        Blocking => 0,
    ) or die Future::IO::Redis::Error::Connection->new(
        message => "Cannot create socket: $!",
        host    => $self->{host},
        port    => $self->{port},
    );

    # Build sockaddr
    my $addr = inet_aton($self->{host})
        or die Future::IO::Redis::Error::Connection->new(
            message => "Cannot resolve host: $self->{host}",
            host    => $self->{host},
            port    => $self->{port},
        );
    my $sockaddr = pack_sockaddr_in($self->{port}, $addr);

    # Connect with timeout using Future->wait_any
    my $connect_f = Future::IO->connect($socket, $sockaddr);
    my $timeout_f = Future::IO->sleep($self->{connect_timeout})->then(sub {
        return Future->fail('connect_timeout');
    });

    my $wait_f = Future->wait_any($connect_f, $timeout_f);

    # Use followed_by to handle both success and failure without await propagating failure
    my $result_f = $wait_f->followed_by(sub {
        my ($f) = @_;
        return Future->done($f);  # wrap the future itself
    });

    my $completed_f = await $result_f;

    # Now check the result
    if ($completed_f->is_failed) {
        my ($error) = $completed_f->failure;
        close $socket;

        if ($error eq 'connect_timeout') {
            die Future::IO::Redis::Error::Timeout->new(
                message => "Connect timed out after $self->{connect_timeout}s",
                timeout => $self->{connect_timeout},
            );
        }
        die Future::IO::Redis::Error::Connection->new(
            message => "$error",
            host    => $self->{host},
            port    => $self->{port},
        );
    }

    # TLS upgrade if enabled
    if ($self->{tls}) {
        eval {
            $socket = await $self->_tls_upgrade($socket);
        };
        if ($@) {
            close $socket;
            die $@;
        }
    }

    $self->{socket} = $socket;
    $self->{parser} = _parser_class()->new(api => 1);
    $self->{connected} = 1;
    $self->{inflight} = [];

    # Run Redis protocol handshake (AUTH, SELECT, CLIENT SETNAME)
    await $self->_redis_handshake;

    # Fire on_connect callback and reset reconnect counter
    if ($self->{on_connect}) {
        $self->{on_connect}->($self);
    }
    $self->{_reconnect_attempt} = 0;

    return $self;
}

# Redis protocol handshake after TCP connect
async sub _redis_handshake {
    my ($self) = @_;

    # AUTH (password or username+password for ACL)
    if ($self->{password}) {
        my @auth_args = ('AUTH');
        push @auth_args, $self->{username} if $self->{username};
        push @auth_args, $self->{password};

        my $cmd = $self->_build_command(@auth_args);
        await $self->_send($cmd);

        my $response = await $self->_read_response();
        my $result = $self->_decode_response($response);

        # AUTH returns OK on success, throws on failure
        unless ($result && $result eq 'OK') {
            die Future::IO::Redis::Error::Redis->new(
                message => "Authentication failed: $result",
                type    => 'NOAUTH',
            );
        }
    }

    # SELECT database
    if ($self->{database} && $self->{database} != 0) {
        my $cmd = $self->_build_command('SELECT', $self->{database});
        await $self->_send($cmd);

        my $response = await $self->_read_response();
        my $result = $self->_decode_response($response);

        unless ($result && $result eq 'OK') {
            die Future::IO::Redis::Error::Redis->new(
                message => "SELECT failed: $result",
                type    => 'ERR',
            );
        }
    }

    # CLIENT SETNAME
    if ($self->{client_name}) {
        my $cmd = $self->_build_command('CLIENT', 'SETNAME', $self->{client_name});
        await $self->_send($cmd);

        my $response = await $self->_read_response();
        # Ignore result - SETNAME failing shouldn't prevent connection
    }
}

# Disconnect from Redis
sub disconnect {
    my ($self, $reason) = @_;
    $reason //= 'client_disconnect';

    my $was_connected = $self->{connected};

    if ($self->{socket}) {
        close $self->{socket};
        $self->{socket} = undef;
    }
    $self->{connected} = 0;
    $self->{parser} = undef;

    if ($was_connected && $self->{on_disconnect}) {
        $self->{on_disconnect}->($self, $reason);
    }

    return $self;
}

# Build Redis command in RESP format
sub _build_command {
    my ($self, @args) = @_;

    my $cmd = "*" . scalar(@args) . "\r\n";
    for my $arg (@args) {
        $arg //= '';
        my $bytes = "$arg";  # stringify
        utf8::encode($bytes) if utf8::is_utf8($bytes);
        $cmd .= "\$" . length($bytes) . "\r\n" . $bytes . "\r\n";
    }
    return $cmd;
}

# Send raw data
async sub _send {
    my ($self, $data) = @_;
    await Future::IO->write_exactly($self->{socket}, $data);
    return length($data);
}

# Read and parse one response
async sub _read_response {
    my ($self) = @_;

    # First check if parser already has a complete message
    # (from previous read that contained multiple responses)
    if (my $msg = $self->{parser}->get_message) {
        return $msg;
    }

    # Read until we get a complete message
    while (1) {
        my $buf = await Future::IO->read($self->{socket}, 65536);

        # EOF
        if (!defined $buf || length($buf) == 0) {
            die "Connection closed by server";
        }

        $self->{parser}->parse($buf);

        if (my $msg = $self->{parser}->get_message) {
            return $msg;
        }
    }
}

# Calculate deadline based on command type
sub _calculate_deadline {
    my ($self, $cmd, @args) = @_;

    $cmd = uc($cmd // '');

    # Blocking commands get extended deadline
    if ($cmd =~ /^(BLPOP|BRPOP|BLMOVE|BRPOPLPUSH|BLMPOP|BZPOPMIN|BZPOPMAX|BZMPOP)$/) {
        # Last arg is the timeout for these commands
        my $server_timeout = $args[-1] // 0;
        return time() + $server_timeout + $self->{blocking_timeout_buffer};
    }

    if ($cmd =~ /^(XREAD|XREADGROUP)$/) {
        # XREAD/XREADGROUP have BLOCK option
        for my $i (0 .. $#args - 1) {
            if (uc($args[$i]) eq 'BLOCK') {
                my $block_ms = $args[$i + 1] // 0;
                return time() + ($block_ms / 1000) + $self->{blocking_timeout_buffer};
            }
        }
    }

    # Normal commands use request_timeout
    return time() + $self->{request_timeout};
}

# Non-blocking TLS upgrade
async sub _tls_upgrade {
    my ($self, $socket) = @_;

    require IO::Socket::SSL;

    # Build SSL options
    my %ssl_opts = (
        SSL_startHandshake => 0,  # Don't block during start_SSL!
    );

    if (ref $self->{tls} eq 'HASH') {
        $ssl_opts{SSL_ca_file}    = $self->{tls}{ca_file} if $self->{tls}{ca_file};
        $ssl_opts{SSL_cert_file}  = $self->{tls}{cert_file} if $self->{tls}{cert_file};
        $ssl_opts{SSL_key_file}   = $self->{tls}{key_file} if $self->{tls}{key_file};

        if (exists $self->{tls}{verify}) {
            $ssl_opts{SSL_verify_mode} = $self->{tls}{verify}
                ? IO::Socket::SSL::SSL_VERIFY_PEER()
                : IO::Socket::SSL::SSL_VERIFY_NONE();
        } else {
            $ssl_opts{SSL_verify_mode} = IO::Socket::SSL::SSL_VERIFY_PEER();
        }
    } else {
        $ssl_opts{SSL_verify_mode} = IO::Socket::SSL::SSL_VERIFY_PEER();
    }

    # Start SSL (does not block because SSL_startHandshake => 0)
    IO::Socket::SSL->start_SSL($socket, %ssl_opts)
        or die Future::IO::Redis::Error::Connection->new(
            message => "SSL setup failed: " . IO::Socket::SSL::errstr(),
            host    => $self->{host},
            port    => $self->{port},
        );

    # Drive handshake with non-blocking loop
    my $deadline = time() + $self->{connect_timeout};

    while (1) {
        # Check timeout
        if (time() >= $deadline) {
            die Future::IO::Redis::Error::Timeout->new(
                message => "TLS handshake timed out",
                timeout => $self->{connect_timeout},
            );
        }

        # Attempt handshake step
        my $rv = $socket->connect_SSL;

        if ($rv) {
            # Handshake complete!
            return $socket;
        }

        # Check what the handshake needs
        my $remaining = $deadline - time();
        $remaining = 0.1 if $remaining <= 0;

        if ($IO::Socket::SSL::SSL_ERROR == IO::Socket::SSL::SSL_ERROR_WANT_READ()) {
            # Wait for socket to become readable with timeout
            my $read_f = Future::IO->waitfor_readable($socket);
            my $timeout_f = Future::IO->sleep($remaining)->then(sub {
                return Future->fail('tls_timeout');
            });

            my $wait_f = Future->wait_any($read_f, $timeout_f);
            await $wait_f;

            if ($wait_f->is_failed) {
                die Future::IO::Redis::Error::Timeout->new(
                    message => "TLS handshake timed out",
                    timeout => $self->{connect_timeout},
                );
            }
        }
        elsif ($IO::Socket::SSL::SSL_ERROR == IO::Socket::SSL::SSL_ERROR_WANT_WRITE()) {
            # Wait for socket to become writable with timeout
            my $write_f = Future::IO->waitfor_writable($socket);
            my $timeout_f = Future::IO->sleep($remaining)->then(sub {
                return Future->fail('tls_timeout');
            });

            my $wait_f = Future->wait_any($write_f, $timeout_f);
            await $wait_f;

            if ($wait_f->is_failed) {
                die Future::IO::Redis::Error::Timeout->new(
                    message => "TLS handshake timed out",
                    timeout => $self->{connect_timeout},
                );
            }
        }
        else {
            # Actual error
            die Future::IO::Redis::Error::Connection->new(
                message => "TLS handshake failed: " . IO::Socket::SSL::errstr(),
                host    => $self->{host},
                port    => $self->{port},
            );
        }
    }
}

# Reconnect with exponential backoff
async sub _reconnect {
    my ($self) = @_;

    while (!$self->{connected}) {
        $self->{_reconnect_attempt}++;
        my $delay = $self->_calculate_backoff($self->{_reconnect_attempt});

        eval {
            await $self->connect;
        };

        if ($@) {
            my $error = $@;

            # Fire on_error callback
            if ($self->{on_error}) {
                $self->{on_error}->($self, $error);
            }

            # Wait before next attempt
            await Future::IO->sleep($delay);
        }
    }
}

# Execute a Redis command
async sub command {
    my ($self, @args) = @_;

    # If disconnected and reconnect enabled, try to reconnect
    if (!$self->{connected} && $self->{reconnect}) {
        await $self->_reconnect;
    }

    die Future::IO::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    my $cmd = $self->_build_command(@args);

    # Calculate deadline based on command type
    my $deadline = $self->_calculate_deadline($args[0], @args[1..$#args]);

    # Send command
    await $self->_send($cmd);

    # Read response with timeout
    my $response = await $self->_read_response_with_deadline($deadline, \@args);
    return $self->_decode_response($response);
}

# Read response with deadline enforcement
async sub _read_response_with_deadline {
    my ($self, $deadline, $cmd_ref) = @_;

    # First check if parser already has a complete message
    if (my $msg = $self->{parser}->get_message) {
        return $msg;
    }

    # Read until we get a complete message
    while (1) {
        my $remaining = $deadline - time();

        if ($remaining <= 0) {
            $self->_reset_connection;
            die Future::IO::Redis::Error::Timeout->new(
                message        => "Request timed out after $self->{request_timeout}s",
                command        => $cmd_ref,
                timeout        => $self->{request_timeout},
                maybe_executed => 1,  # already sent the command
            );
        }

        # Use wait_any for timeout
        my $read_f = Future::IO->read($self->{socket}, 65536);
        my $timeout_f = Future::IO->sleep($remaining)->then(sub {
            return Future->fail('read_timeout');
        });

        my $wait_f = Future->wait_any($read_f, $timeout_f);
        await $wait_f;

        if ($wait_f->is_failed) {
            my ($error) = $wait_f->failure;
            if ($error eq 'read_timeout') {
                $self->_reset_connection;
                die Future::IO::Redis::Error::Timeout->new(
                    message        => "Request timed out after $self->{request_timeout}s",
                    command        => $cmd_ref,
                    timeout        => $self->{request_timeout},
                    maybe_executed => 1,
                );
            }
            $self->_reset_connection;
            die Future::IO::Redis::Error::Connection->new(
                message => "$error",
            );
        }

        # Get the read result
        my $buf = $wait_f->get;

        # EOF
        if (!defined $buf || length($buf) == 0) {
            $self->_reset_connection;
            die Future::IO::Redis::Error::Connection->new(
                message => "Connection closed by server",
            );
        }

        $self->{parser}->parse($buf);

        if (my $msg = $self->{parser}->get_message) {
            return $msg;
        }
    }
}

# Reset connection after timeout (stream is desynced)
sub _reset_connection {
    my ($self, $reason) = @_;
    $reason //= 'timeout';

    my $was_connected = $self->{connected};

    if ($self->{socket}) {
        close $self->{socket};
        $self->{socket} = undef;
    }

    $self->{connected} = 0;
    $self->{parser} = undef;
    $self->{inflight} = [];

    if ($was_connected && $self->{on_disconnect}) {
        $self->{on_disconnect}->($self, $reason);
    }
}

# Decode Protocol::Redis response to Perl value
sub _decode_response {
    my ($self, $msg) = @_;

    return undef unless $msg;

    my $type = $msg->{type};
    my $data = $msg->{data};

    # Simple string (+)
    if ($type eq '+') {
        return $data;
    }
    # Error (-)
    elsif ($type eq '-') {
        die "Redis error: $data";
    }
    # Integer (:)
    elsif ($type eq ':') {
        return 0 + $data;
    }
    # Bulk string ($)
    elsif ($type eq '$') {
        return $data;  # undef for null bulk
    }
    # Array (*)
    elsif ($type eq '*') {
        return undef unless defined $data;  # null array
        return [ map { $self->_decode_response($_) } @$data ];
    }

    return $data;
}

# ============================================================================
# Convenience Commands
# ============================================================================

async sub ping {
    my ($self) = @_;
    return await $self->command('PING');
}

async sub set {
    my ($self, $key, $value, %opts) = @_;
    my @cmd = ('SET', $key, $value);
    push @cmd, 'EX', $opts{ex} if exists $opts{ex};
    push @cmd, 'PX', $opts{px} if exists $opts{px};
    push @cmd, 'NX' if $opts{nx};
    push @cmd, 'XX' if $opts{xx};
    return await $self->command(@cmd);
}

async sub get {
    my ($self, $key) = @_;
    return await $self->command('GET', $key);
}

async sub del {
    my ($self, @keys) = @_;
    return await $self->command('DEL', @keys);
}

async sub incr {
    my ($self, $key) = @_;
    return await $self->command('INCR', $key);
}

async sub lpush {
    my ($self, $key, @values) = @_;
    return await $self->command('LPUSH', $key, @values);
}

async sub rpush {
    my ($self, $key, @values) = @_;
    return await $self->command('RPUSH', $key, @values);
}

async sub lpop {
    my ($self, $key) = @_;
    return await $self->command('LPOP', $key);
}

async sub lrange {
    my ($self, $key, $start, $stop) = @_;
    return await $self->command('LRANGE', $key, $start, $stop);
}

async sub keys {
    my ($self, $pattern) = @_;
    return await $self->command('KEYS', $pattern // '*');
}

async sub flushdb {
    my ($self) = @_;
    return await $self->command('FLUSHDB');
}

# ============================================================================
# PUB/SUB
# ============================================================================

async sub publish {
    my ($self, $channel, $message) = @_;
    return await $self->command('PUBLISH', $channel, $message);
}

# Subscribe to channels - returns a message iterator
async sub subscribe {
    my ($self, @channels) = @_;

    die "Not connected" unless $self->{connected};
    die "Already in subscribe mode" if $self->{subscribing};

    my $cmd = $self->_build_command('SUBSCRIBE', @channels);
    await $self->_send($cmd);

    # Read subscription confirmations
    for my $ch (@channels) {
        my $msg = await $self->_read_response();
        # Response: ['subscribe', $channel, $count]
    }

    $self->{subscribing} = 1;

    return Future::IO::Redis::Subscription->new(redis => $self);
}

# Read next pubsub message (blocking)
async sub _read_pubsub_message {
    my ($self) = @_;

    my $msg = await $self->_read_response();

    # Message format: ['message', $channel, $payload]
    # or: ['pmessage', $pattern, $channel, $payload]
    return $msg;
}

# ============================================================================
# Pipelining
# ============================================================================

sub pipeline {
    my ($self) = @_;
    return Future::IO::Redis::Pipeline->new(redis => $self);
}

# Execute multiple commands, return all responses
async sub _execute_pipeline {
    my ($self, $commands) = @_;

    die "Not connected" unless $self->{connected};

    # Send all commands
    my $data = '';
    for my $cmd (@$commands) {
        $data .= $self->_build_command(@$cmd);
    }
    await $self->_send($data);

    # Read all responses
    my @responses;
    my $count = scalar @$commands;
    for my $i (1 .. $count) {
        my $msg = await $self->_read_response();
        push @responses, $self->_decode_response($msg);
    }

    return \@responses;
}

# ============================================================================
# Helper Classes
# ============================================================================

package Future::IO::Redis::Subscription;

use Future::AsyncAwait;

sub new {
    my ($class, %args) = @_;
    return bless { redis => $args{redis} }, $class;
}

async sub next_message {
    my ($self) = @_;
    my $msg = await $self->{redis}->_read_pubsub_message();

    if (ref $msg eq 'ARRAY' && $msg->[0] eq 'message') {
        return {
            channel => $msg->[1],
            message => $msg->[2],
        };
    }

    return $msg;
}

sub unsubscribe {
    my ($self) = @_;
    $self->{redis}{subscribing} = 0;
    # Would need to send UNSUBSCRIBE and read confirmation
}

package Future::IO::Redis::Pipeline;

use Future::AsyncAwait;

sub new {
    my ($class, %args) = @_;
    return bless {
        redis => $args{redis},
        commands => [],
    }, $class;
}

sub add {
    my ($self, @cmd) = @_;
    push @{$self->{commands}}, \@cmd;
    return $self;
}

# Convenience methods for pipeline
sub set { shift->add('SET', @_) }
sub get { shift->add('GET', @_) }
sub incr { shift->add('INCR', @_) }
sub del { shift->add('DEL', @_) }

async sub execute {
    my ($self) = @_;
    return await $self->{redis}->_execute_pipeline($self->{commands});
}

1;

__END__

=head1 NAME

Future::IO::Redis - Non-blocking Redis client using Future::IO

=head1 SYNOPSIS

    use Future::IO::Redis;
    use Future::AsyncAwait;
    use IO::Async::Loop;
    use Future::IO::Impl::IOAsync;

    my $loop = IO::Async::Loop->new;

    my $redis = Future::IO::Redis->new(host => 'localhost', port => 6379);

    # Use await keyword for async operations
    (async sub {
        await $redis->connect;

        # Basic commands
        await $redis->set('foo', 'bar');
        my $value = await $redis->get('foo');

        # Pipelining
        my $results = await $redis->pipeline
            ->set('a', 1)
            ->set('b', 2)
            ->get('a')
            ->get('b')
            ->execute;

        # Pub/Sub
        my $sub = await $redis->subscribe('news');
        while (my $msg = await $sub->next_message) {
            say "Got: $msg->{message} on $msg->{channel}";
        }
    })->();

    $loop->run;

=head1 DESCRIPTION

Future::IO::Redis provides a non-blocking Redis client built on Future::IO,
making it event-loop agnostic. It works with IO::Async, AnyEvent, UV, or
any other Future::IO implementation.

=cut
