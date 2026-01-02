# Future::IO::Redis Phase 7: Observability & Fork Safety

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement production observability with OpenTelemetry tracing, metrics collection, debug logging with credential redaction, and fork safety for prefork servers.

**Architecture:** Telemetry.pm provides pluggable hooks for OpenTelemetry tracer/meter. Debug logging with automatic credential redaction. PID tracking detects fork and creates fresh connections.

**Tech Stack:** Perl 5.18+, Future::AsyncAwait, OpenTelemetry (optional)

**Prerequisite:** Phases 1-6 complete (connection, commands, transactions, scripting, blocking, SCAN, pipelining, pubsub, pool)

---

## Task Overview

| Task | Focus | Files |
|------|-------|-------|
| 18 | Observability | `lib/Future/IO/Redis/Telemetry.pm`, `t/94-observability/*.t` |
| 19 | Fork Safety | `t/10-connection/fork-safety.t`, modify `lib/Future/IO/Redis.pm` |

---

## Task 18: Observability (OpenTelemetry, Metrics, Debug Logging)

**Files:**
- Create: `lib/Future/IO/Redis/Telemetry.pm`
- Create: `t/94-observability/tracing.t`
- Create: `t/94-observability/metrics.t`
- Create: `t/94-observability/debug.t`
- Create: `t/94-observability/redaction.t`
- Modify: `lib/Future/IO/Redis.pm` (add telemetry hooks)

### Step 1: Create test directory

Run: `mkdir -p t/94-observability`

### Step 2: Write credential redaction test

```perl
# t/94-observability/redaction.t
use Test2::V0;
use Future::IO::Redis::Telemetry;

subtest 'AUTH password redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'AUTH', 'supersecret'
    );
    is($formatted, 'AUTH [REDACTED]', 'single password redacted');
};

subtest 'AUTH user password redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'AUTH', 'myuser', 'mysecretpass'
    );
    is($formatted, 'AUTH myuser [REDACTED]', 'ACL password redacted, username visible');
};

subtest 'CONFIG SET requirepass redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'CONFIG', 'SET', 'requirepass', 'newpassword'
    );
    is($formatted, 'CONFIG SET requirepass [REDACTED]', 'password config redacted');
};

subtest 'CONFIG SET masterauth redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'CONFIG', 'SET', 'masterauth', 'replicapass'
    );
    is($formatted, 'CONFIG SET masterauth [REDACTED]', 'masterauth redacted');
};

subtest 'CONFIG SET non-password not redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'CONFIG', 'SET', 'maxmemory', '100mb'
    );
    is($formatted, 'CONFIG SET maxmemory 100mb', 'non-password config visible');
};

subtest 'CONFIG GET not redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'CONFIG', 'GET', 'maxmemory'
    );
    is($formatted, 'CONFIG GET maxmemory', 'CONFIG GET visible');
};

subtest 'MIGRATE AUTH redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'MIGRATE', 'host', '6379', 'key', '0', '5000', 'AUTH', 'password'
    );
    like($formatted, qr/AUTH \[REDACTED\]/, 'MIGRATE AUTH password redacted');
};

subtest 'MIGRATE AUTH2 redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'MIGRATE', 'host', '6379', 'key', '0', '5000', 'AUTH2', 'user', 'pass'
    );
    like($formatted, qr/AUTH2 user \[REDACTED\]/, 'MIGRATE AUTH2 password redacted');
};

subtest 'regular commands not redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'GET', 'mykey'
    );
    is($formatted, 'GET mykey', 'GET visible');

    $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'SET', 'mykey', 'myvalue'
    );
    is($formatted, 'SET mykey myvalue', 'SET visible');

    $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'HSET', 'hash', 'field', 'value'
    );
    is($formatted, 'HSET hash field value', 'HSET visible');
};

subtest 'HELLO AUTH redacted' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'HELLO', '3', 'AUTH', 'user', 'pass'
    );
    like($formatted, qr/AUTH user \[REDACTED\]/, 'HELLO AUTH redacted');
};

subtest 'case insensitive' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'auth', 'password'
    );
    is($formatted, 'AUTH [REDACTED]', 'lowercase auth redacted');

    $formatted = Future::IO::Redis::Telemetry::format_command_for_log(
        'Auth', 'Password'
    );
    is($formatted, 'AUTH [REDACTED]', 'mixed case auth redacted');
};

subtest 'empty command' => sub {
    my $formatted = Future::IO::Redis::Telemetry::format_command_for_log();
    is($formatted, '', 'empty command returns empty string');
};

done_testing;
```

### Step 3: Run test to verify it fails

Run: `prove -l t/94-observability/redaction.t`
Expected: FAIL (Telemetry.pm not implemented)

### Step 4: Write Telemetry.pm

```perl
# lib/Future/IO/Redis/Telemetry.pm
package Future::IO::Redis::Telemetry;

use strict;
use warnings;
use 5.018;

use Time::HiRes qw(time);

our $VERSION = '0.001';

# Commands with sensitive arguments that need redaction
our %REDACT_RULES = (
    AUTH => sub {
        my (@args) = @_;
        if (@args == 1) {
            # AUTH password
            return ('[REDACTED]');
        }
        elsif (@args >= 2) {
            # AUTH username password
            return ($args[0], '[REDACTED]');
        }
        return @args;
    },

    CONFIG => sub {
        my (@args) = @_;
        return @args unless @args >= 3;

        my $subcommand = uc($args[0] // '');
        if ($subcommand eq 'SET') {
            my $param = lc($args[1] // '');
            if ($param =~ /^(requirepass|masterauth|masteruser|user)$/) {
                return ($args[0], $args[1], '[REDACTED]');
            }
        }
        return @args;
    },

    MIGRATE => sub {
        my (@args) = @_;
        my @result;

        for (my $i = 0; $i <= $#args; $i++) {
            my $arg = $args[$i];
            my $uc_arg = uc($arg // '');

            if ($uc_arg eq 'AUTH' && defined $args[$i + 1]) {
                push @result, $arg, '[REDACTED]';
                $i++;  # Skip password
            }
            elsif ($uc_arg eq 'AUTH2' && defined $args[$i + 1] && defined $args[$i + 2]) {
                push @result, $arg, $args[$i + 1], '[REDACTED]';
                $i += 2;  # Skip username and password
            }
            else {
                push @result, $arg;
            }
        }

        return @result;
    },

    HELLO => sub {
        my (@args) = @_;
        my @result;

        for (my $i = 0; $i <= $#args; $i++) {
            my $arg = $args[$i];
            my $uc_arg = uc($arg // '');

            if ($uc_arg eq 'AUTH' && defined $args[$i + 1] && defined $args[$i + 2]) {
                push @result, $arg, $args[$i + 1], '[REDACTED]';
                $i += 2;  # Skip username and password
            }
            else {
                push @result, $arg;
            }
        }

        return @result;
    },

    ACL => sub {
        my (@args) = @_;
        return @args unless @args >= 1;

        my $subcommand = uc($args[0] // '');
        if ($subcommand eq 'SETUSER' && @args >= 3) {
            # ACL SETUSER username ...rules...
            # Redact any >password patterns
            my @result = ($args[0], $args[1]);
            for my $i (2 .. $#args) {
                if ($args[$i] =~ /^>/) {
                    push @result, '>[REDACTED]';
                }
                else {
                    push @result, $args[$i];
                }
            }
            return @result;
        }
        return @args;
    },
);

# Format command for logging with redaction
sub format_command_for_log {
    my (@cmd) = @_;

    return '' unless @cmd;

    my $name = uc($cmd[0] // '');
    my @args = @cmd[1 .. $#cmd];

    if (my $redactor = $REDACT_RULES{$name}) {
        @args = $redactor->(@args);
    }

    return join(' ', $name, @args);
}

# Format command for OTel span (same redaction, optional args)
sub format_command_for_span {
    my ($include_args, $redact, @cmd) = @_;

    return '' unless @cmd;

    my $name = uc($cmd[0] // '');

    return $name unless $include_args;

    my @args = @cmd[1 .. $#cmd];

    if ($redact && (my $redactor = $REDACT_RULES{$name})) {
        @args = $redactor->(@args);
    }

    return join(' ', $name, @args);
}

#
# OpenTelemetry Integration
#

sub new {
    my ($class, %args) = @_;

    return bless {
        tracer           => $args{tracer},         # OTel tracer
        meter            => $args{meter},          # OTel meter
        debug            => $args{debug},          # Debug logger
        include_args     => $args{include_args} // 1,
        redact           => $args{redact} // 1,
        host             => $args{host} // 'localhost',
        port             => $args{port} // 6379,
        database         => $args{database} // 0,

        # Metrics (lazy-initialized)
        _commands_counter   => undef,
        _commands_histogram => undef,
        _connections_gauge  => undef,
        _errors_counter     => undef,
        _reconnects_counter => undef,
        _pipeline_histogram => undef,
    }, $class;
}

# Initialize metrics (call after meter is set)
sub _init_metrics {
    my ($self) = @_;

    return unless $self->{meter};
    return if $self->{_metrics_initialized};

    my $meter = $self->{meter};

    $self->{_commands_counter} = $meter->create_counter(
        name        => 'redis.commands.total',
        description => 'Total Redis commands executed',
        unit        => '1',
    );

    $self->{_commands_histogram} = $meter->create_histogram(
        name        => 'redis.commands.duration',
        description => 'Redis command latency',
        unit        => 'ms',
    );

    $self->{_connections_gauge} = $meter->create_up_down_counter(
        name        => 'redis.connections.active',
        description => 'Current active connections',
        unit        => '1',
    );

    $self->{_errors_counter} = $meter->create_counter(
        name        => 'redis.errors.total',
        description => 'Total Redis errors by type',
        unit        => '1',
    );

    $self->{_reconnects_counter} = $meter->create_counter(
        name        => 'redis.reconnects.total',
        description => 'Total reconnection attempts',
        unit        => '1',
    );

    $self->{_pipeline_histogram} = $meter->create_histogram(
        name        => 'redis.pipeline.size',
        description => 'Commands per pipeline',
        unit        => '1',
    );

    $self->{_metrics_initialized} = 1;
}

# Start a span for a command
sub start_command_span {
    my ($self, @cmd) = @_;

    return undef unless $self->{tracer};

    my $command_name = uc($cmd[0] // 'UNKNOWN');
    my $span_name = "redis.$command_name";

    my $statement = format_command_for_span(
        $self->{include_args},
        $self->{redact},
        @cmd
    );

    my $span = $self->{tracer}->create_span(
        name       => $span_name,
        kind       => 'client',
        attributes => {
            'db.system'              => 'redis',
            'db.operation'           => $command_name,
            'db.statement'           => $statement,
            'net.peer.name'          => $self->{host},
            'net.peer.port'          => $self->{port},
            'db.redis.database_index' => $self->{database},
        },
    );

    return {
        span       => $span,
        start_time => time(),
        command    => $command_name,
    };
}

# End a command span
sub end_command_span {
    my ($self, $context, $error) = @_;

    return unless $context && $context->{span};

    my $elapsed_ms = (time() - $context->{start_time}) * 1000;

    if ($error) {
        $context->{span}->set_status('error', "$error");
        $context->{span}->record_exception($error);
    }

    $context->{span}->end;

    # Record metrics
    $self->_record_command_metrics($context->{command}, $elapsed_ms, $error);
}

# Record command metrics
sub _record_command_metrics {
    my ($self, $command, $elapsed_ms, $error) = @_;

    $self->_init_metrics;

    my %labels = (command => $command);

    if ($self->{_commands_counter}) {
        $self->{_commands_counter}->add(1, \%labels);
    }

    if ($self->{_commands_histogram}) {
        $self->{_commands_histogram}->record($elapsed_ms, \%labels);
    }

    if ($error && $self->{_errors_counter}) {
        my $error_type = ref($error) || 'unknown';
        $error_type =~ s/.*:://;  # Strip package prefix
        $self->{_errors_counter}->add(1, { type => $error_type });
    }
}

# Record pipeline metrics
sub record_pipeline {
    my ($self, $size, $elapsed_ms) = @_;

    $self->_init_metrics;

    if ($self->{_pipeline_histogram}) {
        $self->{_pipeline_histogram}->record($size);
    }

    if ($self->{_commands_histogram}) {
        $self->{_commands_histogram}->record($elapsed_ms, { command => 'PIPELINE' });
    }
}

# Record connection event
sub record_connection {
    my ($self, $delta) = @_;

    $self->_init_metrics;

    if ($self->{_connections_gauge}) {
        $self->{_connections_gauge}->add($delta);
    }
}

# Record reconnection attempt
sub record_reconnect {
    my ($self) = @_;

    $self->_init_metrics;

    if ($self->{_reconnects_counter}) {
        $self->{_reconnects_counter}->add(1);
    }
}

#
# Debug Logging
#

sub log_send {
    my ($self, @cmd) = @_;

    return unless $self->{debug};

    my $formatted = format_command_for_log(@cmd);

    if (ref $self->{debug} eq 'CODE') {
        $self->{debug}->('send', $formatted);
    }
    else {
        warn "[REDIS SEND] $formatted\n";
    }
}

sub log_recv {
    my ($self, $result, $elapsed_ms) = @_;

    return unless $self->{debug};

    my $summary = _summarize_result($result);
    my $msg = sprintf("[REDIS RECV] %s (%.2fms)", $summary, $elapsed_ms);

    if (ref $self->{debug} eq 'CODE') {
        $self->{debug}->('recv', $msg);
    }
    else {
        warn "$msg\n";
    }
}

sub log_error {
    my ($self, $error) = @_;

    return unless $self->{debug};

    my $msg = "[REDIS ERROR] $error";

    if (ref $self->{debug} eq 'CODE') {
        $self->{debug}->('error', $msg);
    }
    else {
        warn "$msg\n";
    }
}

sub log_event {
    my ($self, $event, $details) = @_;

    return unless $self->{debug};

    my $msg = "[REDIS EVENT] $event" . ($details ? ": $details" : '');

    if (ref $self->{debug} eq 'CODE') {
        $self->{debug}->('event', $msg);
    }
    else {
        warn "$msg\n";
    }
}

# Summarize result without exposing values
sub _summarize_result {
    my ($result) = @_;

    return 'nil' unless defined $result;

    if (ref $result eq 'ARRAY') {
        return 'array[' . scalar(@$result) . ']';
    }
    elsif (ref $result eq 'HASH') {
        return 'hash{' . scalar(keys %$result) . '}';
    }
    elsif (ref $result && $result->isa('Future::IO::Redis::Error')) {
        return 'error: ' . $result->message;
    }
    elsif (length($result) > 100) {
        return 'string[' . length($result) . ' bytes]';
    }
    else {
        # Short strings are OK to show type
        return 'OK' if $result eq 'OK';
        return 'PONG' if $result eq 'PONG';
        return 'QUEUED' if $result eq 'QUEUED';
        return 'integer' if $result =~ /^-?\d+$/;
        return 'string[' . length($result) . ']';
    }
}

1;

__END__

=head1 NAME

Future::IO::Redis::Telemetry - Observability for Redis client

=head1 SYNOPSIS

    use Future::IO::Redis;
    use OpenTelemetry;

    my $redis = Future::IO::Redis->new(
        host => 'localhost',

        # OpenTelemetry integration
        otel_tracer => OpenTelemetry->tracer_provider->tracer('redis'),
        otel_meter  => OpenTelemetry->meter_provider->meter('redis'),

        # Debug logging
        debug => 1,                    # log to STDERR
        debug => sub {                 # custom logger
            my ($direction, $data) = @_;
            $logger->debug("[$direction] $data");
        },
    );

=head1 DESCRIPTION

Provides OpenTelemetry tracing, metrics collection, and debug logging
with automatic credential redaction.

=head2 Credential Redaction

Sensitive commands are automatically redacted in logs and traces:

=over 4

=item * AUTH password -> AUTH [REDACTED]

=item * AUTH user pass -> AUTH user [REDACTED]

=item * CONFIG SET requirepass x -> CONFIG SET requirepass [REDACTED]

=item * MIGRATE ... AUTH pass -> MIGRATE ... AUTH [REDACTED]

=back

=head2 Metrics

=over 4

=item * redis.commands.total - Counter by command name

=item * redis.commands.duration - Histogram of latency

=item * redis.connections.active - Gauge of current connections

=item * redis.errors.total - Counter by error type

=item * redis.reconnects.total - Counter of reconnect attempts

=item * redis.pipeline.size - Histogram of pipeline batch sizes

=back

=head2 Traces

Each command creates a span with:

=over 4

=item * db.system: redis

=item * db.operation: command name

=item * db.statement: redacted command

=item * net.peer.name: host

=item * net.peer.port: port

=item * db.redis.database_index: database

=back

=cut
```

### Step 5: Run redaction test

Run: `prove -l t/94-observability/redaction.t`
Expected: PASS

### Step 6: Write debug logging test

```perl
# t/94-observability/debug.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'debug => 1 logs to STDERR' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, shift };

        my $redis = Future::IO::Redis->new(
            host  => 'localhost',
            debug => 1,
        );
        $loop->await($redis->connect);
        $loop->await($redis->ping);
        $redis->disconnect;

        ok(@warnings > 0, 'warnings captured');
        ok((grep { /REDIS/ } @warnings), 'logs contain REDIS prefix');
        ok((grep { /PING/ } @warnings), 'logs contain PING command');
    };

    subtest 'debug => sub logs to custom logger' => sub {
        my @logs;

        my $redis = Future::IO::Redis->new(
            host  => 'localhost',
            debug => sub {
                my ($direction, $data) = @_;
                push @logs, { direction => $direction, data => $data };
            },
        );
        $loop->await($redis->connect);
        $loop->await($redis->set('debug:key', 'value'));
        $loop->await($redis->get('debug:key'));
        $redis->disconnect;

        ok(@logs > 0, 'custom logger called');

        my @sends = grep { $_->{direction} eq 'send' } @logs;
        my @recvs = grep { $_->{direction} eq 'recv' } @logs;

        ok(@sends > 0, 'send logs captured');
        ok(@recvs > 0, 'recv logs captured');

        ok((grep { $_->{data} =~ /SET debug:key/ } @sends), 'SET logged');
        ok((grep { $_->{data} =~ /GET debug:key/ } @sends), 'GET logged');
    };

    subtest 'debug logs redact AUTH' => sub {
        my @logs;

        my $redis = Future::IO::Redis->new(
            host     => 'localhost',
            password => 'testpass',  # Will send AUTH
            debug    => sub {
                my ($direction, $data) = @_;
                push @logs, $data;
            },
        );

        # Connect will try AUTH (may fail, that's OK)
        eval { $loop->await($redis->connect) };

        # Check that password was redacted
        my @auth_logs = grep { /AUTH/ } @logs;
        ok(@auth_logs > 0, 'AUTH command logged');

        for my $log (@auth_logs) {
            unlike($log, qr/testpass/, 'password not in log');
            like($log, qr/\[REDACTED\]/, 'password redacted');
        }
    };

    subtest 'debug disabled by default' => sub {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, shift };

        my $redis = Future::IO::Redis->new(host => 'localhost');
        $loop->await($redis->connect);
        $loop->await($redis->ping);
        $redis->disconnect;

        my @redis_warnings = grep { /REDIS/ } @warnings;
        is(scalar @redis_warnings, 0, 'no Redis debug logs by default');
    };

    subtest 'response values not logged' => sub {
        my @logs;

        my $redis = Future::IO::Redis->new(
            host  => 'localhost',
            debug => sub { push @logs, $_[1] },
        );
        $loop->await($redis->connect);
        $loop->await($redis->set('debug:secret', 'supersecretvalue'));
        $loop->await($redis->get('debug:secret'));
        $redis->disconnect;

        # Value should not appear in logs
        for my $log (@logs) {
            unlike($log, qr/supersecretvalue/, 'secret value not in log');
        }

        # Cleanup
        $loop->await($test_redis->del('debug:secret'));
    };
}

done_testing;
```

### Step 7: Run debug logging test

Run: `prove -l t/94-observability/debug.t`
Expected: PASS (after integrating Telemetry into Future::IO::Redis)

### Step 8: Integrate Telemetry into Future::IO::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
use Future::IO::Redis::Telemetry;

# In new():
sub new {
    my ($class, %args) = @_;

    my $self = bless {
        # ... existing fields ...

        # Telemetry
        debug          => $args{debug},
        otel_tracer    => $args{otel_tracer},
        otel_meter     => $args{otel_meter},
        otel_include_args => $args{otel_include_args} // 1,
        otel_redact    => $args{otel_redact} // 1,
    }, $class;

    # Initialize telemetry if any observability enabled
    if ($self->{debug} || $self->{otel_tracer} || $self->{otel_meter}) {
        $self->{_telemetry} = Future::IO::Redis::Telemetry->new(
            tracer       => $self->{otel_tracer},
            meter        => $self->{otel_meter},
            debug        => $self->{debug},
            include_args => $self->{otel_include_args},
            redact       => $self->{otel_redact},
            host         => $self->{host},
            port         => $self->{port},
            database     => $self->{database} // 0,
        );
    }

    return $self;
}

# In command(), add telemetry hooks:
async sub command {
    my ($self, @cmd) = @_;

    # Start span and log
    my $span_context;
    if ($self->{_telemetry}) {
        $span_context = $self->{_telemetry}->start_command_span(@cmd);
        $self->{_telemetry}->log_send(@cmd);
    }

    my $start_time = time();
    my $result;
    my $error;

    eval {
        $result = await $self->_execute_command(@cmd);
    };
    $error = $@;

    my $elapsed_ms = (time() - $start_time) * 1000;

    # End span and log
    if ($self->{_telemetry}) {
        if ($error) {
            $self->{_telemetry}->log_error($error);
        }
        else {
            $self->{_telemetry}->log_recv($result, $elapsed_ms);
        }
        $self->{_telemetry}->end_command_span($span_context, $error);
    }

    die $error if $error;
    return $result;
}

# In connect(), add telemetry:
async sub connect {
    my ($self) = @_;

    # ... existing connect logic ...

    if ($self->{_telemetry}) {
        $self->{_telemetry}->record_connection(1);
        $self->{_telemetry}->log_event('connected', "$self->{host}:$self->{port}");
    }
}

# In disconnect():
sub disconnect {
    my ($self) = @_;

    if ($self->{_telemetry}) {
        $self->{_telemetry}->record_connection(-1);
        $self->{_telemetry}->log_event('disconnected');
    }

    # ... existing disconnect logic ...
}

# In reconnect logic:
sub _on_reconnect {
    my ($self) = @_;

    if ($self->{_telemetry}) {
        $self->{_telemetry}->record_reconnect();
        $self->{_telemetry}->log_event('reconnecting');
    }

    # ... existing reconnect logic ...
}

# In pipeline execute:
async sub _execute_pipeline {
    my ($self, $commands) = @_;

    my $start_time = time();
    my $result = await $self->_do_execute_pipeline($commands);
    my $elapsed_ms = (time() - $start_time) * 1000;

    if ($self->{_telemetry}) {
        $self->{_telemetry}->record_pipeline(scalar @$commands, $elapsed_ms);
    }

    return $result;
}
```

### Step 9: Write OpenTelemetry tracing test

```perl
# t/94-observability/tracing.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;

# Mock OpenTelemetry tracer
package MockSpan {
    sub new {
        my ($class, %args) = @_;
        return bless {
            name       => $args{name},
            attributes => $args{attributes},
            status     => undef,
            ended      => 0,
        }, $class;
    }

    sub set_status {
        my ($self, $status, $msg) = @_;
        $self->{status} = { code => $status, message => $msg };
    }

    sub record_exception {
        my ($self, $error) = @_;
        $self->{exception} = $error;
    }

    sub end {
        my ($self) = @_;
        $self->{ended} = 1;
    }
}

package MockTracer {
    sub new {
        my ($class) = @_;
        return bless { spans => [] }, $class;
    }

    sub create_span {
        my ($self, %args) = @_;
        my $span = MockSpan->new(%args);
        push @{$self->{spans}}, $span;
        return $span;
    }

    sub spans { @{shift->{spans}} }
    sub clear { shift->{spans} = [] }
}

package main;

use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'tracer creates spans for commands' => sub {
        my $tracer = MockTracer->new;

        my $redis = Future::IO::Redis->new(
            host        => 'localhost',
            otel_tracer => $tracer,
        );
        $loop->await($redis->connect);
        $loop->await($redis->set('trace:key', 'value'));
        $loop->await($redis->get('trace:key'));
        $redis->disconnect;

        my @spans = $tracer->spans;
        ok(@spans >= 2, 'spans created for commands');

        # Find SET span
        my ($set_span) = grep { $_->{name} eq 'redis.SET' } @spans;
        ok($set_span, 'SET span created');
        is($set_span->{attributes}{'db.system'}, 'redis', 'db.system attribute');
        is($set_span->{attributes}{'db.operation'}, 'SET', 'db.operation attribute');
        like($set_span->{attributes}{'db.statement'}, qr/SET trace:key/, 'db.statement attribute');
        is($set_span->{attributes}{'net.peer.name'}, 'localhost', 'net.peer.name attribute');
        ok($set_span->{ended}, 'span ended');

        # Cleanup
        $loop->await($test_redis->del('trace:key'));
    };

    subtest 'span records error on command failure' => sub {
        my $tracer = MockTracer->new;

        my $redis = Future::IO::Redis->new(
            host        => 'localhost',
            otel_tracer => $tracer,
        );
        $loop->await($redis->connect);

        # Cause an error - INCR on string
        $loop->await($redis->set('trace:error', 'notanumber'));
        eval {
            $loop->await($redis->incr('trace:error'));
        };

        my @spans = $tracer->spans;
        my ($incr_span) = grep { $_->{name} eq 'redis.INCR' } @spans;
        ok($incr_span, 'INCR span created');
        is($incr_span->{status}{code}, 'error', 'span status is error');
        ok($incr_span->{exception}, 'exception recorded');

        $redis->disconnect;
        $loop->await($test_redis->del('trace:error'));
    };

    subtest 'AUTH password redacted in span' => sub {
        my $tracer = MockTracer->new;

        my $redis = Future::IO::Redis->new(
            host        => 'localhost',
            password    => 'secret123',
            otel_tracer => $tracer,
        );

        # Connect may fail AUTH, that's OK
        eval { $loop->await($redis->connect) };

        my @spans = $tracer->spans;
        my ($auth_span) = grep { $_->{name} eq 'redis.AUTH' } @spans;

        if ($auth_span) {
            unlike($auth_span->{attributes}{'db.statement'}, qr/secret123/,
                'password not in span');
            like($auth_span->{attributes}{'db.statement'}, qr/\[REDACTED\]/,
                'password redacted in span');
        }
    };

    subtest 'otel_include_args => 0 hides args' => sub {
        my $tracer = MockTracer->new;

        my $redis = Future::IO::Redis->new(
            host             => 'localhost',
            otel_tracer      => $tracer,
            otel_include_args => 0,
        );
        $loop->await($redis->connect);
        $loop->await($redis->set('trace:noargs', 'secretvalue'));
        $redis->disconnect;

        my @spans = $tracer->spans;
        my ($set_span) = grep { $_->{name} eq 'redis.SET' } @spans;
        is($set_span->{attributes}{'db.statement'}, 'SET', 'only command name, no args');

        $loop->await($test_redis->del('trace:noargs'));
    };
}

done_testing;
```

### Step 10: Write metrics test

```perl
# t/94-observability/metrics.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;

# Mock OpenTelemetry meter
package MockCounter {
    sub new {
        my ($class, %args) = @_;
        return bless {
            name  => $args{name},
            value => 0,
            calls => [],
        }, $class;
    }

    sub add {
        my ($self, $value, $labels) = @_;
        $self->{value} += $value;
        push @{$self->{calls}}, { value => $value, labels => $labels };
    }

    sub value { shift->{value} }
    sub calls { @{shift->{calls}} }
}

package MockHistogram {
    sub new {
        my ($class, %args) = @_;
        return bless {
            name    => $args{name},
            values  => [],
        }, $class;
    }

    sub record {
        my ($self, $value, $labels) = @_;
        push @{$self->{values}}, { value => $value, labels => $labels };
    }

    sub values { @{shift->{values}} }
    sub count  { scalar @{shift->{values}} }
}

package MockMeter {
    sub new {
        my ($class) = @_;
        return bless {
            counters   => {},
            histograms => {},
        }, $class;
    }

    sub create_counter {
        my ($self, %args) = @_;
        my $counter = MockCounter->new(%args);
        $self->{counters}{$args{name}} = $counter;
        return $counter;
    }

    sub create_histogram {
        my ($self, %args) = @_;
        my $histogram = MockHistogram->new(%args);
        $self->{histograms}{$args{name}} = $histogram;
        return $histogram;
    }

    sub create_up_down_counter {
        my ($self, %args) = @_;
        return $self->create_counter(%args);
    }

    sub counter    { shift->{counters}{shift()} }
    sub histogram  { shift->{histograms}{shift()} }
}

package main;

use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'meter records command counts' => sub {
        my $meter = MockMeter->new;

        my $redis = Future::IO::Redis->new(
            host       => 'localhost',
            otel_meter => $meter,
        );
        $loop->await($redis->connect);

        # Execute some commands
        for (1..5) {
            $loop->await($redis->set("metrics:key:$_", "value$_"));
        }
        for (1..3) {
            $loop->await($redis->get("metrics:key:$_"));
        }

        $redis->disconnect;

        my $commands_counter = $meter->counter('redis.commands.total');
        ok($commands_counter, 'commands counter created');
        ok($commands_counter->value >= 8, 'commands counted');

        my @calls = $commands_counter->calls;
        my @set_calls = grep { $_->{labels}{command} eq 'SET' } @calls;
        my @get_calls = grep { $_->{labels}{command} eq 'GET' } @calls;

        is(scalar @set_calls, 5, '5 SET commands recorded');
        is(scalar @get_calls, 3, '3 GET commands recorded');

        # Cleanup
        $loop->await($test_redis->del(map { "metrics:key:$_" } 1..5));
    };

    subtest 'meter records command latency' => sub {
        my $meter = MockMeter->new;

        my $redis = Future::IO::Redis->new(
            host       => 'localhost',
            otel_meter => $meter,
        );
        $loop->await($redis->connect);
        $loop->await($redis->ping);
        $redis->disconnect;

        my $histogram = $meter->histogram('redis.commands.duration');
        ok($histogram, 'duration histogram created');
        ok($histogram->count >= 1, 'latency recorded');

        my @values = $histogram->values;
        for my $v (@values) {
            ok($v->{value} >= 0, "latency >= 0 ($v->{value}ms)");
            ok($v->{value} < 1000, "latency < 1s ($v->{value}ms)");
        }
    };

    subtest 'meter records connection count' => sub {
        my $meter = MockMeter->new;

        my $redis = Future::IO::Redis->new(
            host       => 'localhost',
            otel_meter => $meter,
        );
        $loop->await($redis->connect);

        my $connections = $meter->counter('redis.connections.active');
        ok($connections, 'connections counter created');
        is($connections->value, 1, 'connection recorded');

        $redis->disconnect;

        is($connections->value, 0, 'disconnection recorded');
    };

    subtest 'meter records errors' => sub {
        my $meter = MockMeter->new;

        my $redis = Future::IO::Redis->new(
            host       => 'localhost',
            otel_meter => $meter,
        );
        $loop->await($redis->connect);

        # Cause an error
        $loop->await($redis->set('metrics:error', 'string'));
        eval { $loop->await($redis->incr('metrics:error')) };

        $redis->disconnect;

        my $errors = $meter->counter('redis.errors.total');
        ok($errors, 'errors counter created');
        ok($errors->value >= 1, 'error recorded');

        $loop->await($test_redis->del('metrics:error'));
    };

    subtest 'meter records pipeline size' => sub {
        my $meter = MockMeter->new;

        my $redis = Future::IO::Redis->new(
            host       => 'localhost',
            otel_meter => $meter,
        );
        $loop->await($redis->connect);

        my $pipe = $redis->pipeline;
        $pipe->set('metrics:pipe:1', '1');
        $pipe->set('metrics:pipe:2', '2');
        $pipe->set('metrics:pipe:3', '3');
        $loop->await($pipe->execute);

        $redis->disconnect;

        my $pipeline_hist = $meter->histogram('redis.pipeline.size');
        ok($pipeline_hist, 'pipeline histogram created');

        my @values = $pipeline_hist->values;
        ok(@values >= 1, 'pipeline size recorded');
        is($values[0]{value}, 3, 'pipeline size is 3');

        $loop->await($test_redis->del('metrics:pipe:1', 'metrics:pipe:2', 'metrics:pipe:3'));
    };
}

done_testing;
```

### Step 11: Run all observability tests

Run: `prove -l t/94-observability/`
Expected: PASS

### Step 12: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 13: Commit

```bash
git add lib/Future/IO/Redis/Telemetry.pm lib/Future/IO/Redis.pm t/94-observability/
git commit -m "$(cat <<'EOF'
feat: implement observability (OpenTelemetry, metrics, debug logging)

Telemetry.pm:
- OpenTelemetry tracing with span per command
- Metrics: commands.total, commands.duration, connections.active,
  errors.total, reconnects.total, pipeline.size
- Debug logging to STDERR or custom callback
- Automatic credential redaction

Redacted commands:
- AUTH password -> AUTH [REDACTED]
- AUTH user pass -> AUTH user [REDACTED]
- CONFIG SET requirepass x -> CONFIG SET requirepass [REDACTED]
- CONFIG SET masterauth x -> CONFIG SET masterauth [REDACTED]
- MIGRATE ... AUTH pass -> MIGRATE ... AUTH [REDACTED]
- MIGRATE ... AUTH2 user pass -> MIGRATE ... AUTH2 user [REDACTED]
- HELLO ... AUTH user pass -> HELLO ... AUTH user [REDACTED]
- ACL SETUSER ... >password -> ACL SETUSER ... >[REDACTED]

Configuration options:
- otel_tracer: OpenTelemetry tracer
- otel_meter: OpenTelemetry meter
- otel_include_args: Include args in db.statement (default: 1)
- otel_redact: Redact sensitive args (default: 1)
- debug: 1 for STDERR, or sub for custom logger

Span attributes:
- db.system: redis
- db.operation: command name
- db.statement: redacted command
- net.peer.name: host
- net.peer.port: port
- db.redis.database_index: database

Response values are NOT logged (only type/size summary).

EOF
)"
```

---

## Task 19: Fork Safety

**Files:**
- Create: `t/10-connection/fork-safety.t`
- Modify: `lib/Future/IO/Redis.pm` (add PID tracking)
- Modify: `lib/Future/IO/Redis/Pool.pm` (add PID tracking)

### Step 1: Write fork safety test

```perl
# t/10-connection/fork-safety.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use POSIX qw(_exit);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Future::IO::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'connection tracks PID' => sub {
        ok($redis->{_pid}, 'PID tracked');
        is($redis->{_pid}, $$, 'PID matches current process');
    };

    subtest 'connection detects fork and reconnects' => sub {
        plan skip_all => 'fork() not supported on this platform'
            unless $^O ne 'MSWin32';

        # Store a value
        $loop->await($redis->set('fork:test', 'parent_value'));

        my $pipe_to_child;
        my $pipe_from_child;
        pipe($pipe_from_child, $pipe_to_child) or die "pipe: $!";

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child process
            close $pipe_from_child;

            # The redis connection should detect PID change
            my $child_loop = IO::Async::Loop->new;

            # This should auto-reconnect because PID changed
            my $result;
            eval {
                $result = $child_loop->await($redis->get('fork:test'));
            };

            if ($@) {
                print $pipe_to_child "ERROR: $@\n";
            }
            elsif ($result eq 'parent_value') {
                print $pipe_to_child "SUCCESS\n";
            }
            else {
                print $pipe_to_child "WRONG: $result\n";
            }

            close $pipe_to_child;
            _exit(0);
        }

        # Parent process
        close $pipe_to_child;

        # Wait for child
        waitpid($pid, 0);

        my $child_output = do { local $/; <$pipe_from_child> };
        close $pipe_from_child;

        like($child_output, qr/SUCCESS/, 'child got correct value after fork');
    };

    subtest 'pool handles fork correctly' => sub {
        plan skip_all => 'fork() not supported on this platform'
            unless $^O ne 'MSWin32';

        require Future::IO::Redis::Pool;

        my $pool = Future::IO::Redis::Pool->new(
            host => 'localhost',
            min  => 1,
            max  => 3,
        );

        # Get a connection
        my $conn1 = $loop->await($pool->acquire);
        $loop->await($conn1->set('fork:pool', 'pool_value'));
        $pool->release($conn1);

        my $pipe_to_child;
        my $pipe_from_child;
        pipe($pipe_from_child, $pipe_to_child) or die "pipe: $!";

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child process
            close $pipe_from_child;

            my $child_loop = IO::Async::Loop->new;

            # Pool should detect fork and create new connections
            my $result;
            eval {
                $result = $child_loop->await($pool->with(async sub {
                    my ($r) = @_;
                    await $r->get('fork:pool');
                }));
            };

            if ($@) {
                print $pipe_to_child "ERROR: $@\n";
            }
            elsif ($result eq 'pool_value') {
                print $pipe_to_child "SUCCESS\n";
            }
            else {
                print $pipe_to_child "WRONG: $result\n";
            }

            close $pipe_to_child;
            _exit(0);
        }

        # Parent
        close $pipe_to_child;
        waitpid($pid, 0);

        my $child_output = do { local $/; <$pipe_from_child> };
        close $pipe_from_child;

        like($child_output, qr/SUCCESS/, 'pool worked in child after fork');

        # Cleanup
        $loop->await($redis->del('fork:pool'));
    };

    subtest 'parent connection still works after fork' => sub {
        plan skip_all => 'fork() not supported on this platform'
            unless $^O ne 'MSWin32';

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ($pid == 0) {
            # Child just exits
            _exit(0);
        }

        waitpid($pid, 0);

        # Parent connection should still work
        my $result = $loop->await($redis->ping);
        is($result, 'PONG', 'parent connection works after fork');
    };

    # Cleanup
    $loop->await($redis->del('fork:test'));
    $redis->disconnect;
}

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/10-connection/fork-safety.t`
Expected: FAIL (PID tracking not implemented)

### Step 3: Add PID tracking to Future::IO::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
# In new():
sub new {
    my ($class, %args) = @_;

    my $self = bless {
        # ... existing fields ...

        # Fork safety
        _pid => $$,
    }, $class;

    return $self;
}

# In connect():
async sub connect {
    my ($self) = @_;

    # Track PID at connection time
    $self->{_pid} = $$;

    # ... existing connect logic ...
}

# Add method to check if fork occurred
sub _check_fork {
    my ($self) = @_;

    if ($self->{_pid} != $$) {
        # Fork detected - invalidate connection
        $self->{connected} = 0;
        $self->{socket} = undef;
        $self->{_pid} = $$;

        if ($self->{_telemetry}) {
            $self->{_telemetry}->log_event('fork_detected', "old PID: $self->{_pid}, new PID: $$");
        }

        return 1;  # Fork occurred
    }

    return 0;
}

# Modify command() to check for fork:
async sub command {
    my ($self, @cmd) = @_;

    # Check for fork
    if ($self->_check_fork) {
        # Reconnect if configured
        if ($self->{reconnect}) {
            await $self->connect;
        }
        else {
            die Future::IO::Redis::Error::Disconnected->new(
                message => "Connection invalid after fork",
            );
        }
    }

    # Check connected
    if (!$self->{connected}) {
        if ($self->{reconnect}) {
            await $self->connect;
        }
        else {
            die Future::IO::Redis::Error::Disconnected->new(
                message => "Not connected",
            );
        }
    }

    # ... rest of command execution ...
}
```

### Step 4: Add PID tracking to Pool.pm

Edit `lib/Future/IO/Redis/Pool.pm`:

```perl
# In new():
sub new {
    my ($class, %args) = @_;

    my $self = bless {
        # ... existing fields ...

        # Fork safety
        _pid => $$,
    }, $class;

    return $self;
}

# Add fork check method
sub _check_fork {
    my ($self) = @_;

    if ($self->{_pid} != $$) {
        # Fork detected - invalidate all connections
        $self->_clear_all_connections;
        $self->{_pid} = $$;
        return 1;
    }

    return 0;
}

sub _clear_all_connections {
    my ($self) = @_;

    # Clear idle connections without closing (parent owns the sockets)
    $self->{_idle} = [];

    # Clear active connections (caller still has reference)
    $self->{_active} = {};

    # Cancel waiters
    for my $waiter (@{$self->{_waiters}}) {
        $waiter->fail("Pool invalidated after fork") unless $waiter->is_ready;
    }
    $self->{_waiters} = [];
}

# Modify acquire() to check for fork:
async sub acquire {
    my ($self) = @_;

    # Check for fork
    $self->_check_fork;

    # ... rest of acquire logic ...
}

# Modify release() to check for fork:
sub release {
    my ($self, $conn) = @_;

    return unless $conn;

    # Check for fork - if forked, don't return to pool
    if ($self->_check_fork) {
        # Pool was cleared, just drop this connection
        return;
    }

    # ... rest of release logic ...
}
```

### Step 5: Run fork safety test

Run: `prove -l t/10-connection/fork-safety.t`
Expected: PASS

### Step 6: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 7: Commit

```bash
git add lib/Future/IO/Redis.pm lib/Future/IO/Redis/Pool.pm t/10-connection/fork-safety.t
git commit -m "$(cat <<'EOF'
feat: implement fork safety with PID tracking

Fork detection:
- Track PID at connection/pool creation
- Check PID before command execution
- Auto-reconnect after fork (if reconnect enabled)
- Throw error if not reconnect-enabled

Connection behavior after fork:
- Invalidate socket (parent owns it)
- Clear connected flag
- Update PID to current process
- Reconnect on next command

Pool behavior after fork:
- Clear all idle connections
- Clear active connection tracking
- Cancel waiting acquirers
- Fresh connections in child process

Test coverage:
- Connection tracks PID
- Connection auto-reconnects after fork
- Pool works correctly in child process
- Parent connection unaffected by fork

This enables safe use with prefork servers (Starman, etc.)
where worker processes inherit the parent's Redis connection
but need their own fresh connection.

EOF
)"
```

---

## Execution Checklist

Before starting each task:
- [ ] All existing tests pass (`prove -l t/`)
- [ ] Non-blocking proof passes (`prove -l t/02-nonblocking.t`)

After completing each task:
- [ ] New tests pass
- [ ] All tests pass (no regressions)
- [ ] Non-blocking proof passes
- [ ] Changes committed

---

## Phase 7 Summary

| Task | Deliverable | Tests |
|------|-------------|-------|
| 18 | `lib/Future/IO/Redis/Telemetry.pm` | `t/94-observability/*.t` |
| 19 | Fork safety (PID tracking) | `t/10-connection/fork-safety.t` |

**Observability Features:**
- OpenTelemetry tracing with span per command
- Metrics: commands, latency, connections, errors, reconnects, pipeline size
- Debug logging to STDERR or custom callback
- Automatic credential redaction for AUTH, CONFIG, MIGRATE, HELLO, ACL

**Fork Safety Features:**
- PID tracking in connection and pool
- Auto-reconnect after fork (with reconnect enabled)
- Pool invalidation after fork
- Works with prefork servers (Starman, etc.)

**Total new files:** 6
**Estimated tests:** 60+ assertions

---

## Next Phase

After Phase 7 is complete, Phase 8 will cover:
- **Task 20:** Reliability Testing (Redis restart, network partition)
- **Task 21:** Integration Testing & Benchmarks
- **Task 22:** Documentation & CPAN Release
