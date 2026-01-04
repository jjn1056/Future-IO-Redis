# Async::Redis Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the sketch Redis client into a production-ready, rock-solid implementation with full command coverage, reliability features, and connection pooling.

**Architecture:** Layered design with Connection (state machine), Commands (auto-generated), Pool (connection management), and specialized modules for Pipeline, Transaction, PubSub, and Scripting. All operations non-blocking via Future::IO.

**Tech Stack:** Perl 5.18+, Future::IO 0.17+, Future::AsyncAwait, Protocol::Redis (or XS variant), IO::Socket::SSL (optional for TLS)

---

## Phase Overview

| Phase | Focus | Tasks |
|-------|-------|-------|
| 1 | Error Classes & URI | 1-2 |
| 2 | Timeouts | 3 |
| 3 | Reconnection | 4 |
| 4 | Auth & TLS | 5-6 |
| 5 | Command Generation | 7-9 |
| 6 | Transactions & Scripting | 10-11 |
| 7 | Blocking & SCAN | 12-13 |
| 8 | Pipeline Refinement | 14-15 |
| 9 | PubSub & Pool | 16-17 |
| 10 | Observability & Polish | 18-22 |

---

## Task 1: Error Exception Classes

**Files:**
- Create: `lib/Future/IO/Redis/Error.pm`
- Create: `lib/Future/IO/Redis/Error/Connection.pm`
- Create: `lib/Future/IO/Redis/Error/Timeout.pm`
- Create: `lib/Future/IO/Redis/Error/Protocol.pm`
- Create: `lib/Future/IO/Redis/Error/Redis.pm`
- Create: `lib/Future/IO/Redis/Error/Disconnected.pm`
- Create: `t/01-unit/error.t`

**Step 1: Write the failing test**

```perl
# t/01-unit/error.t
use Test2::V0;
use Async::Redis::Error;
use Async::Redis::Error::Connection;
use Async::Redis::Error::Timeout;
use Async::Redis::Error::Protocol;
use Async::Redis::Error::Redis;
use Async::Redis::Error::Disconnected;

subtest 'Error base class' => sub {
    my $e = Async::Redis::Error->new(message => 'test error');
    ok($e->isa('Async::Redis::Error'), 'isa Error');
    is($e->message, 'test error', 'message accessor');
    like("$e", qr/test error/, 'stringifies');
};

subtest 'Connection error' => sub {
    my $e = Async::Redis::Error::Connection->new(
        message => 'connection lost',
        host    => 'localhost',
        port    => 6379,
    );
    ok($e->isa('Async::Redis::Error'), 'isa base Error');
    ok($e->isa('Async::Redis::Error::Connection'), 'isa Connection');
    is($e->host, 'localhost', 'host accessor');
    is($e->port, 6379, 'port accessor');
};

subtest 'Timeout error' => sub {
    my $e = Async::Redis::Error::Timeout->new(
        message => 'request timed out',
        command => ['GET', 'key'],
        timeout => 5,
    );
    ok($e->isa('Async::Redis::Error::Timeout'), 'isa Timeout');
    is_deeply($e->command, ['GET', 'key'], 'command accessor');
    is($e->timeout, 5, 'timeout accessor');
};

subtest 'Protocol error' => sub {
    my $e = Async::Redis::Error::Protocol->new(
        message => 'unexpected response type',
        data    => '+OK',
    );
    ok($e->isa('Async::Redis::Error::Protocol'), 'isa Protocol');
};

subtest 'Redis error' => sub {
    my $e = Async::Redis::Error::Redis->new(
        message => 'WRONGTYPE Operation against a key holding the wrong kind of value',
        type    => 'WRONGTYPE',
    );
    ok($e->isa('Async::Redis::Error::Redis'), 'isa Redis');
    is($e->type, 'WRONGTYPE', 'error type parsed');
    ok($e->is_wrongtype, 'is_wrongtype predicate');
    ok(!$e->is_oom, 'is_oom false for WRONGTYPE');
};

subtest 'Disconnected error' => sub {
    my $e = Async::Redis::Error::Disconnected->new(
        message => 'command queue full',
    );
    ok($e->isa('Async::Redis::Error::Disconnected'), 'isa Disconnected');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/01-unit/error.t`
Expected: FAIL with "Can't locate Future/IO/Redis/Error.pm"

**Step 3: Write Error base class**

```perl
# lib/Future/IO/Redis/Error.pm
package Async::Redis::Error;

use strict;
use warnings;
use 5.018;

use overload '""' => 'stringify', fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub message { shift->{message} }

sub stringify {
    my ($self) = @_;
    return $self->message // ref($self);
}

sub throw {
    my $self = shift;
    $self = $self->new(@_) unless ref $self;
    die $self;
}

1;
```

**Step 4: Write Connection error subclass**

```perl
# lib/Future/IO/Redis/Error/Connection.pm
package Async::Redis::Error::Connection;

use strict;
use warnings;
use 5.018;
use parent 'Async::Redis::Error';

sub host { shift->{host} }
sub port { shift->{port} }
sub reason { shift->{reason} }

1;
```

**Step 5: Write Timeout error subclass**

```perl
# lib/Future/IO/Redis/Error/Timeout.pm
package Async::Redis::Error::Timeout;

use strict;
use warnings;
use 5.018;
use parent 'Async::Redis::Error';

sub command { shift->{command} }
sub timeout { shift->{timeout} }
sub maybe_executed { shift->{maybe_executed} }

1;
```

**Step 6: Write Protocol error subclass**

```perl
# lib/Future/IO/Redis/Error/Protocol.pm
package Async::Redis::Error::Protocol;

use strict;
use warnings;
use 5.018;
use parent 'Async::Redis::Error';

sub data { shift->{data} }

1;
```

**Step 7: Write Redis error subclass**

```perl
# lib/Future/IO/Redis/Error/Redis.pm
package Async::Redis::Error::Redis;

use strict;
use warnings;
use 5.018;
use parent 'Async::Redis::Error';

sub type { shift->{type} }

sub is_wrongtype { uc(shift->{type} // '') eq 'WRONGTYPE' }
sub is_oom       { uc(shift->{type} // '') eq 'OOM' }
sub is_busy      { uc(shift->{type} // '') eq 'BUSY' }
sub is_noscript  { uc(shift->{type} // '') eq 'NOSCRIPT' }
sub is_readonly  { uc(shift->{type} // '') eq 'READONLY' }
sub is_loading   { uc(shift->{type} // '') eq 'LOADING' }

sub is_fatal {
    my $self = shift;
    my $type = uc($self->{type} // '');
    return 1 if $type =~ /^(WRONGTYPE|OOM|NOSCRIPT|NOAUTH|NOPERM)$/;
    return 0;
}

1;
```

**Step 8: Write Disconnected error subclass**

```perl
# lib/Future/IO/Redis/Error/Disconnected.pm
package Async::Redis::Error::Disconnected;

use strict;
use warnings;
use 5.018;
use parent 'Async::Redis::Error';

1;
```

**Step 9: Run test to verify it passes**

Run: `prove -l t/01-unit/error.t`
Expected: PASS (all subtests pass)

**Step 10: Run all existing tests**

Run: `prove -l t/`
Expected: PASS (no regressions)

**Step 11: Commit**

```bash
git add lib/Future/IO/Redis/Error.pm lib/Future/IO/Redis/Error/*.pm t/01-unit/error.t
git commit -m "$(cat <<'EOF'
feat: add typed exception classes

- Error base class with message, stringify, throw
- Connection: host, port, reason
- Timeout: command, timeout, maybe_executed
- Protocol: data
- Redis: type, is_* predicates, is_fatal
- Disconnected: for queue full scenario

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: URI Parsing

**Files:**
- Create: `lib/Future/IO/Redis/URI.pm`
- Create: `t/01-unit/uri.t`

**Step 1: Write the failing test**

```perl
# t/01-unit/uri.t
use Test2::V0;
use Async::Redis::URI;

subtest 'basic redis URI' => sub {
    my $uri = Async::Redis::URI->parse('redis://localhost');
    is($uri->host, 'localhost', 'host');
    is($uri->port, 6379, 'default port');
    is($uri->database, 0, 'default database');
    ok(!$uri->password, 'no password');
    ok(!$uri->tls, 'no tls');
};

subtest 'redis URI with port' => sub {
    my $uri = Async::Redis::URI->parse('redis://localhost:6380');
    is($uri->host, 'localhost', 'host');
    is($uri->port, 6380, 'custom port');
};

subtest 'redis URI with password' => sub {
    my $uri = Async::Redis::URI->parse('redis://:secret@localhost');
    is($uri->password, 'secret', 'password parsed');
    ok(!$uri->username, 'no username');
};

subtest 'redis URI with username and password (ACL)' => sub {
    my $uri = Async::Redis::URI->parse('redis://user:pass@localhost');
    is($uri->username, 'user', 'username');
    is($uri->password, 'pass', 'password');
};

subtest 'redis URI with database' => sub {
    my $uri = Async::Redis::URI->parse('redis://localhost/5');
    is($uri->database, 5, 'database from path');
};

subtest 'full redis URI' => sub {
    my $uri = Async::Redis::URI->parse('redis://user:pass@redis.example.com:6380/2');
    is($uri->host, 'redis.example.com', 'host');
    is($uri->port, 6380, 'port');
    is($uri->username, 'user', 'username');
    is($uri->password, 'pass', 'password');
    is($uri->database, 2, 'database');
};

subtest 'rediss (TLS) URI' => sub {
    my $uri = Async::Redis::URI->parse('rediss://localhost:6380');
    ok($uri->tls, 'tls enabled');
    is($uri->port, 6380, 'port');
};

subtest 'unix socket URI' => sub {
    my $uri = Async::Redis::URI->parse('redis+unix:///var/run/redis.sock');
    is($uri->path, '/var/run/redis.sock', 'socket path');
    ok($uri->is_unix, 'is unix socket');
};

subtest 'unix socket with database' => sub {
    my $uri = Async::Redis::URI->parse('redis+unix:///var/run/redis.sock?db=3');
    is($uri->path, '/var/run/redis.sock', 'socket path');
    is($uri->database, 3, 'database from query');
};

subtest 'invalid URI throws' => sub {
    ok(dies { Async::Redis::URI->parse('http://localhost') },
       'non-redis scheme throws');
    ok(dies { Async::Redis::URI->parse('not a uri') },
       'invalid format throws');
};

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/01-unit/uri.t`
Expected: FAIL with "Can't locate Future/IO/Redis/URI.pm"

**Step 3: Write URI parser**

```perl
# lib/Future/IO/Redis/URI.pm
package Async::Redis::URI;

use strict;
use warnings;
use 5.018;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub parse {
    my ($class, $uri_string) = @_;

    # Match: scheme://[user:pass@]host[:port][/database][?query]
    # Or:    redis+unix://[:password@]/path[?query]

    my %parsed = (
        host     => 'localhost',
        port     => 6379,
        database => 0,
        tls      => 0,
    );

    # Handle unix socket
    if ($uri_string =~ m{^redis\+unix://(?::([^@]*)@)?(/[^?]+)(?:\?(.*))?$}) {
        $parsed{password} = $1 if defined $1;
        $parsed{path} = $2;
        $parsed{is_unix} = 1;

        if (defined $3) {
            my %query = map { split /=/, $_, 2 } split /&/, $3;
            $parsed{database} = $query{db} if exists $query{db};
        }

        return $class->new(%parsed);
    }

    # Match standard redis:// or rediss:// URI
    unless ($uri_string =~ m{^(rediss?)://(.*)$}) {
        die "Invalid Redis URI: must start with redis:// or rediss://";
    }

    my $scheme = $1;
    my $rest = $2;
    $parsed{tls} = 1 if $scheme eq 'rediss';

    # Parse userinfo@host:port/database
    my ($userinfo, $hostinfo);

    if ($rest =~ /^([^@]*)@(.*)$/) {
        $userinfo = $1;
        $hostinfo = $2;
    } else {
        $hostinfo = $rest;
    }

    # Parse userinfo (user:pass or :pass)
    if (defined $userinfo && $userinfo ne '') {
        if ($userinfo =~ /^:(.*)$/) {
            $parsed{password} = $1;
        } elsif ($userinfo =~ /^([^:]*):(.*)$/) {
            $parsed{username} = $1;
            $parsed{password} = $2;
        } else {
            $parsed{username} = $userinfo;
        }
    }

    # Parse host:port/database
    if ($hostinfo =~ m{^([^:/]+)(?::(\d+))?(?:/(\d+))?$}) {
        $parsed{host} = $1;
        $parsed{port} = $2 if defined $2;
        $parsed{database} = $3 if defined $3;
    } elsif ($hostinfo eq '' || $hostinfo =~ m{^/(\d+)?$}) {
        # Empty host means localhost
        $parsed{database} = $1 if defined $1;
    } else {
        die "Invalid Redis URI format: $uri_string";
    }

    return $class->new(%parsed);
}

sub host     { shift->{host} }
sub port     { shift->{port} }
sub path     { shift->{path} }
sub database { shift->{database} }
sub username { shift->{username} }
sub password { shift->{password} }
sub tls      { shift->{tls} }
sub is_unix  { shift->{is_unix} }

1;
```

**Step 4: Run test to verify it passes**

Run: `prove -l t/01-unit/uri.t`
Expected: PASS

**Step 5: Run all tests**

Run: `prove -l t/`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/Future/IO/Redis/URI.pm t/01-unit/uri.t
git commit -m "$(cat <<'EOF'
feat: add URI connection string parser

Supports:
- redis://host:port/database
- redis://:password@host
- redis://user:pass@host (ACL)
- rediss:// (TLS)
- redis+unix:///path/to/socket?db=N

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Timeout Implementation

**Files:**
- Modify: `lib/Future/IO/Redis.pm`
- Create: `t/10-connection/timeout.t`

**Step 1: Write the failing test**

```perl
# t/10-connection/timeout.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Async::Redis::Error::Timeout;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

subtest 'connect timeout fires on unreachable host' => sub {
    my $start = time();

    my $redis = Async::Redis->new(
        host => '10.255.255.1',  # non-routable
        connect_timeout => 0.5,
    );

    my $error;
    eval { $loop->await($redis->connect) };
    $error = $@;

    my $elapsed = time() - $start;

    ok($error, 'connect failed');
    ok($error->isa('Async::Redis::Error::Timeout'), 'error is Timeout');
    ok($elapsed < 1.0, "timed out quickly (${elapsed}s < 1.0s)");
};

subtest 'event loop not blocked during connect timeout' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.05,
        on_tick => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    my $redis = Async::Redis->new(
        host => '10.255.255.1',
        connect_timeout => 0.3,
    );

    eval { $loop->await($redis->connect) };

    $timer->stop;
    $loop->remove($timer);

    ok(@ticks >= 2, "timer ticked " . scalar(@ticks) . " times during timeout");
};

# Skip Redis-dependent tests if not available
SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available", 2 unless $redis;

    subtest 'request timeout fires on slow command' => sub {
        my $redis = Async::Redis->new(
            host => 'localhost',
            request_timeout => 0.5,
        );
        $loop->await($redis->connect);

        my $start = time();
        my $error;
        eval {
            # DEBUG SLEEP blocks server-side for 2 seconds
            $loop->await($redis->command('DEBUG', 'SLEEP', 2));
        };
        $error = $@;
        my $elapsed = time() - $start;

        ok($error, 'command failed');
        ok($error->isa('Async::Redis::Error::Timeout'), 'error is Timeout');
        ok($elapsed < 1.0, "timed out at ${elapsed}s (expected ~0.5s)");
    };

    subtest 'request timeout respects blocking command buffer' => sub {
        my $redis = Async::Redis->new(
            host => 'localhost',
            request_timeout => 1,
            blocking_timeout_buffer => 1,
        );
        $loop->await($redis->connect);

        # BLPOP with 0.5s server timeout should have ~1.5s client deadline
        my $start = time();
        my $result = $loop->await($redis->blpop('nonexistent:queue', 0.5));
        my $elapsed = time() - $start;

        is($result, undef, 'BLPOP returned undef (timeout)');
        ok($elapsed >= 0.4 && $elapsed < 1.0, "waited for server timeout (${elapsed}s)");
    };
}

done_testing;
```

**Step 2: Run test to verify it fails**

Run: `prove -l t/10-connection/timeout.t`
Expected: FAIL (timeout not implemented)

**Step 3: Add timeout parameters to constructor**

Edit `lib/Future/IO/Redis.pm` to add timeout support in `new()`:

```perl
# In new() method, add:
connect_timeout         => $args{connect_timeout} // 10,
read_timeout            => $args{read_timeout} // 30,
write_timeout           => $args{write_timeout} // 30,
request_timeout         => $args{request_timeout} // 5,
blocking_timeout_buffer => $args{blocking_timeout_buffer} // 2,
```

**Step 4: Implement connect timeout**

```perl
# In connect() method, wrap Future::IO->connect with timeout:
my $connect_f = Future::IO->connect($socket, $sockaddr)
    ->timeout($self->{connect_timeout})
    ->on_fail(sub {
        my ($failure) = @_;
        if ($failure =~ /timeout/i) {
            die Async::Redis::Error::Timeout->new(
                message => "Connect timed out after $self->{connect_timeout}s",
                timeout => $self->{connect_timeout},
            );
        }
        die Async::Redis::Error::Connection->new(
            message => $failure,
            host    => $self->{host},
            port    => $self->{port},
        );
    });
await $connect_f;
```

**Step 5: Implement request timeout timer**

```perl
# Add to connection setup:
sub _start_timeout_timer {
    my ($self) = @_;

    # Check every 100ms for timed-out requests
    $self->{timeout_timer} = IO::Async::Timer::Periodic->new(
        interval => 0.1,
        on_tick  => sub { $self->_check_timeouts },
    );
    # Add timer to loop (implementation detail)
}

sub _check_timeouts {
    my ($self) = @_;
    my $now = time();

    for my $entry (@{$self->{inflight}}) {
        if (exists $entry->{deadline} && $now >= $entry->{deadline}) {
            $self->_handle_timeout($entry);
            return;
        }
    }
}

sub _handle_timeout {
    my ($self, $entry) = @_;

    # Fail the timed-out request
    $entry->{future}->fail(
        Async::Redis::Error::Timeout->new(
            message => "Request timed out after $self->{request_timeout}s",
            command => $entry->{command},
            timeout => $self->{request_timeout},
        )
    );

    # Fail all pending requests (connection desynced)
    for my $e (@{$self->{inflight}}) {
        next if $e->{future}->is_ready;
        $e->{future}->fail(
            Async::Redis::Error::Connection->new(
                message => "Connection reset due to timeout",
            )
        );
    }
    @{$self->{inflight}} = ();

    # Reset connection
    $self->_reset_connection;
}
```

**Step 6: Calculate deadline for blocking commands**

```perl
sub _calculate_deadline {
    my ($self, $command, @args) = @_;

    if ($self->_is_blocking_command($command)) {
        # Blocking commands: server_timeout + buffer
        my $server_timeout = $args[-1] // 0;
        return time() + $server_timeout + $self->{blocking_timeout_buffer};
    }

    return time() + $self->{request_timeout};
}

sub _is_blocking_command {
    my ($self, $cmd) = @_;
    return uc($cmd) =~ /^(BLPOP|BRPOP|BLMOVE|BRPOPLPUSH|BLMPOP|BZPOPMIN|BZPOPMAX|BZMPOP|XREAD|XREADGROUP)$/;
}
```

**Step 7: Run test to verify it passes**

Run: `prove -l t/10-connection/timeout.t`
Expected: PASS

**Step 8: Run all tests**

Run: `prove -l t/`
Expected: PASS

**Step 9: Run non-blocking proof**

Run: `prove -l t/02-nonblocking.t`
Expected: PASS (event loop ticks during Redis operations)

**Step 10: Commit**

```bash
git add lib/Future/IO/Redis.pm t/10-connection/timeout.t
git commit -m "$(cat <<'EOF'
feat: implement two-tier timeout system

- connect_timeout: TCP connection establishment
- read_timeout: socket-level silence detection
- request_timeout: per-command deadline (authoritative)
- blocking_timeout_buffer: extra time for BLPOP/BRPOP

Timeout behavior:
- Periodic timer (100ms) checks deadlines
- Timeout = fail request + reset connection (RESP2 constraint)
- All inflight requests fail when one times out

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Tasks 4-22: Remaining Implementation

The remaining tasks follow the same TDD pattern. See the design document `docs/plans/2026-01-01-production-ready-design.md` sections:

| Task | Design Section | Focus |
|------|----------------|-------|
| 4 | Section 1 | Reconnection with exponential backoff |
| 5 | Section 3 | AUTH and SELECT on connect |
| 6 | Section 3 | Non-blocking TLS handshake |
| 7 | Section 11 | bin/generate-commands script |
| 8 | Section 11 | Commands.pm generation |
| 9 | Section 11.1 | KeyExtractor.pm for prefixing |
| 10 | Section 5 | MULTI/EXEC/WATCH transactions |
| 11 | Section 6 | EVAL/EVALSHA Lua scripting |
| 12 | Section 7 | Blocking commands (BLPOP etc.) |
| 13 | Section 8 | SCAN iterators |
| 14 | Section 4 | Pipeline error handling |
| 15 | Section 1 | Auto-pipelining |
| 16 | Section 9 | PubSub refinement |
| 17 | Section 10 | Connection pool with dirty tracking |
| 18 | Section 13 | OpenTelemetry integration |
| 19 | Section 1 | Fork safety |
| 20 | Section 12 | Reliability tests |
| 21 | Section 12 | Integration tests |
| 22 | - | Documentation and CPAN release |

Each task follows the same structure:
1. Write failing test
2. Verify test fails
3. Implement minimal code
4. Verify test passes
5. Run all tests (regression check)
6. Run non-blocking proof
7. Commit

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

## Critical Non-Blocking Verification

After EVERY task, run:

```bash
prove -l t/02-nonblocking.t
```

If this fails, the implementation is broken. Stop and fix before continuing.

The non-blocking test verifies the event loop continues ticking during Redis operations. This is the entire point of this library.
