# Async::Redis Production-Ready Design

**Date:** 2026-01-01
**Status:** Approved

---

## Overview

Design for making Async::Redis a production-ready, rock-solid Redis client. Key goals:

1. **Full command coverage** - Auto-generate from Redis specs (Net::Async::Redis style)
2. **API compatibility** - Match Net::Async::Redis naming conventions
3. **Bulletproof reliability** - Handle connection drops, timeouts, and data integrity
4. **PAGI-Channels ready** - PubSub and connection pooling for channel layer backend

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Protocol** | **RESP2 only (v1.x)** | Protocol::Redis exists, works with all Redis versions, XS-accelerated |
| Command coverage | Auto-generate from redis-doc JSON | Matches Net::Async::Redis, stays current with Redis releases |
| Method naming | snake_case (`cluster_addslots`) | Net::Async::Redis compatibility |
| Error handling | Typed exception classes | Clear failure categories, catchable |
| Reconnection | Automatic with exponential backoff | Production resilience |
| TLS | IO::Socket::SSL (optional dep) | Standard Perl TLS solution |

### Protocol Version: RESP2

**This release (v1.x) implements RESP2 only.**

RESP2 is the legacy Redis protocol supported by all Redis versions. We use Protocol::Redis (with optional XS acceleration) for parsing.

**What this means:**
- Works with Redis 2.x, 3.x, 4.x, 5.x, 6.x, 7.x, 8.x
- PubSub requires dedicated connection (cannot share with commands)
- HGETALL returns array (we convert to hash in transformer)
- No client-side caching support
- No sharded PubSub on same connection

**RESP3 is planned for v2.x** - See `TODO.md` for details. RESP3 would enable:
- Inline PubSub (same connection as commands)
- Native map/set/boolean types
- Client-side caching via invalidation messages
- Sharded PubSub without connection overhead

**Why RESP2 first:**
1. Protocol::Redis already exists and is battle-tested
2. No RESP3 parser exists on CPAN (would need to write one)
3. RESP2 covers all core functionality
4. Faster path to production-ready release
5. RESP3 can be added without breaking API

---

## Section 1: Connection Management

### Constructor Options

```perl
my $redis = Async::Redis->new(
    host              => 'localhost',
    port              => 6379,

    # Or Unix socket
    path              => '/var/run/redis.sock',

    # Or connection URI (overrides host/port/path)
    uri               => 'redis://user:pass@localhost:6379/2',
    uri               => 'rediss://localhost:6380/0',  # TLS
    uri               => 'redis+unix:///var/run/redis.sock?db=1',

    # Timeouts (seconds)
    connect_timeout   => 10,       # TCP connection establishment
    read_timeout      => 30,       # Socket-level silence detection
    write_timeout     => 30,       # Socket write buffer flush
    request_timeout   => 5,        # Per-command deadline (authoritative)
    blocking_timeout_buffer => 2,  # Extra time for BLPOP/BRPOP/etc.

    # Reconnection
    reconnect         => 1,           # enable auto-reconnect
    reconnect_delay   => 0.1,         # initial delay
    reconnect_delay_max => 60,        # max delay (exponential backoff)
    reconnect_jitter  => 0.25,        # randomization factor

    # Events
    on_connect    => sub { my ($redis) = @_; ... },
    on_disconnect => sub { my ($redis, $reason) = @_; ... },
    on_error      => sub { my ($redis, $error) = @_; ... },

    # Queue management
    queue_size        => 1000,      # max commands queued during reconnect

    # Connection identification
    client_name       => 'myapp',   # CLIENT SETNAME on connect

    # Key prefixing (namespace isolation)
    prefix            => 'myapp:',  # auto-prepend to all keys

    # Performance tuning
    read_buffer_size  => 65536,     # socket read buffer (default 64KB)
    write_buffer_size => 65536,     # socket write buffer (default 64KB)
    pipeline_depth    => 100,       # max pipelined commands before flush
);
```

### Behavior

- Commands during disconnect get queued (up to `queue_size` limit)
- On reconnect, AUTH/SELECT replayed automatically
- Exponential backoff: 0.1s -> 0.2s -> 0.4s -> ... -> 60s max
- Jitter prevents thundering herd when many clients reconnect
- `on_disconnect` fires with reason: `connection_lost`, `timeout`, `server_closed`
- Key prefixing uses key extraction strategy (see Section 11.1)
- Fork safety: detect PID change and create fresh connections (for prefork servers)

### Auto-Pipelining

```perl
my $redis = Async::Redis->new(
    auto_pipeline => 1,  # enable auto-pipelining
);

# Commands issued in same event loop tick are batched automatically
my @futures = map { $redis->get("key$_") } (1..100);
my @values = await Future->all(@futures);
# Only 1 network round-trip instead of 100
```

When `auto_pipeline` enabled:
- Commands queued until event loop yields
- All queued commands sent as single pipeline
- Responses distributed to original Futures
- Transparent to caller - same API as non-pipelined

#### Flush Mechanism (Concrete Implementation)

The "event loop yields" behavior requires a precise implementation:

```perl
# AutoPipeline state
has _queue         => [];      # pending commands
has _flush_pending => 0;       # guard against double-scheduling
has _flushing      => 0;       # guard against reentrancy

sub command {
    my ($self, @args) = @_;

    my $future = Future->new;
    push @{$self->{_queue}}, { cmd => \@args, future => $future };

    # Schedule flush exactly once per batch
    unless ($self->{_flush_pending}) {
        $self->{_flush_pending} = 1;
        $self->_schedule_flush;
    }

    return $future;
}

sub _schedule_flush {
    my ($self) = @_;

    # Use event loop's "next tick" mechanism
    # This runs after current code yields but before I/O
    Future::IO->later->on_done(sub {
        $self->_do_flush;
    });
}

sub _do_flush {
    my ($self) = @_;

    # Reentrancy guard - flush must not run inside flush
    return if $self->{_flushing};
    $self->{_flushing} = 1;

    # Reset pending flag before flush (allows new commands to queue)
    $self->{_flush_pending} = 0;

    # Take current queue (new commands go to fresh queue)
    my @batch = splice @{$self->{_queue}};

    if (@batch) {
        # Respect pipeline depth limit
        my $max = $self->{pipeline_depth} // 1000;
        if (@batch > $max) {
            # Put excess back, schedule another flush
            unshift @{$self->{_queue}}, splice(@batch, $max);
            $self->{_flush_pending} = 1;
            $self->_schedule_flush;
        }

        $self->_send_pipeline(\@batch);
    }

    $self->{_flushing} = 0;
}
```

**Key invariants:**

| Rule | Why |
|------|-----|
| `_flush_pending` flag | Prevents scheduling multiple flush callbacks for same batch |
| `_flushing` guard | Prevents reentrancy if callback somehow triggers command |
| `splice @queue` | Atomically takes batch; new commands go to fresh queue |
| `later` not `sleep(0)` | `later` is non-blocking next-tick; `sleep(0)` may block |
| Depth limit with reschedule | Prevents unbounded memory if commands arrive faster than flush |

**Event loop compatibility:**

```perl
# Future::IO->later uses the active implementation:
# - IO::Async: $loop->later(sub { ... })
# - AnyEvent: AE::postpone(sub { ... })
# - UV: $loop->idle(sub { ... })
```

### Retry Strategies

```perl
my $redis = Async::Redis->new(
    # Built-in strategies
    retry => 'exponential',     # default: exponential backoff

    # Or custom retry logic
    retry => sub {
        my ($attempt, $error, $command) = @_;
        return 0 if $attempt > 5;           # give up after 5 tries
        return 0 if $error->is_fatal;       # don't retry fatal errors
        return 0 if $command eq 'SET';      # don't retry writes
        return 0.1 * (2 ** $attempt);       # delay in seconds
    },
);
```

### Command State Tracking

Every command has a state that determines retry safety:

```
┌─────────────────────────────────────────────────────────────────┐
│  Command States                                                 │
│                                                                 │
│  QUEUED ──► WRITTEN ──► RESPONDED                               │
│     │          │            │                                   │
│     │          │            └─► Complete (no retry needed)      │
│     │          │                                                │
│     │          └─► Failure here = MAYBE EXECUTED                │
│     │              (timeout, connection drop after write)       │
│     │              NOT safe to retry by default                 │
│     │                                                           │
│     └─► Failure here = DEFINITELY NOT EXECUTED                  │
│         (connection drop before write)                          │
│         Safe to retry                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Implementation:**

```perl
# Each @inflight entry tracks state
push @inflight, {
    future   => $future,
    deadline => time() + $timeout,
    command  => \@args,
    state    => 'queued',  # queued | written | responded
};

# After successful write
sub _on_write_complete {
    my ($self, $entry) = @_;
    $entry->{state} = 'written';
}

# On response received
sub _on_response {
    my ($self, $response) = @_;
    my $entry = shift @{$self->{inflight}};
    $entry->{state} = 'responded';
    # ... resolve future
}
```

### Retry Safety Rules

**Safe to auto-retry** (command was never sent):
- Connection lost while command still `queued`
- LOADING (Redis still loading dataset)
- BUSY (Lua script in progress, command wasn't executed)

**NOT safe to auto-retry by default** (command may have executed):
- Connection lost after command `written`
- Timeout after command `written`
- Any failure where `state != 'queued'`

**Never retry:**
- WRONGTYPE, OOM, NOSCRIPT, AUTH errors (deterministic failures)
- Commands that succeeded (obviously)

### Timeout + Retry Interaction

**Critical rule:** Timeout after write = maybe executed = no auto-retry.

```perl
sub _handle_timeout {
    my ($self, $entry) = @_;

    if ($entry->{state} eq 'queued') {
        # Never sent - safe to queue for retry after reconnect
        push @{$self->{retry_queue}}, $entry;
    } else {
        # Written but no response - maybe executed
        # Default: fail permanently (safe)
        $entry->{future}->fail(
            Error::Timeout->new(
                message => "Request timed out (maybe executed)",
                maybe_executed => 1,
            )
        );
    }

    # Always reset connection on timeout (RESP2 stream desync)
    $self->_reset_connection;
}
```

**Optional "maybe executed" retry policy:**

```perl
my $redis = Async::Redis->new(
    # For users who accept the risk of duplicate execution
    retry_maybe_executed => 1,  # default: 0 (safe)
);
```

When enabled, commands marked as idempotent retry even after write. This is **dangerous** for non-idempotent commands like `INCR` or `LPUSH`.

### Idempotent Command Marking

```perl
# Mark specific commands as safe to retry even after write
my $redis = Async::Redis->new(
    idempotent_commands => [qw(GET SET SETNX SETEX GETSET)],
);

# Or per-command
await $redis->set('key', 'value', idempotent => 1);
```

**Default idempotent commands:** GET, MGET, EXISTS, TYPE, TTL, PTTL, KEYS, SCAN, INFO, PING, ECHO, DEBUG, TIME, DBSIZE

### Timeout Implementation

**Two-tier timeout model:**

1. **Socket-level timeouts** - Detect dead connections:
```perl
# Wrap Future::IO calls with socket timeouts
my $connect_f = Future::IO->connect($socket, $sockaddr)
    ->timeout($self->{connect_timeout});

my $read_f = Future::IO->read($socket, 65536)
    ->timeout($self->{read_timeout});
```

2. **Request-level timeouts** - Authoritative per-command deadlines:
```perl
# Periodic timer checks deadlines (see Section 2: Timeout Semantics)
# Each @inflight entry has its own deadline
# Timeout = fail request + reset connection (RESP2 constraint)
```

See **Section 2: Timeout Semantics (Precise Definition)** for the full timer-based implementation.

---

## Section 2: Error Handling & Data Integrity

### Exception Classes

```perl
Async::Redis::Error::Connection   # connect failed, connection lost
Async::Redis::Error::Timeout      # read/write/connect timeout
Async::Redis::Error::Protocol     # malformed RESP, unexpected response
Async::Redis::Error::Redis        # Redis error response (WRONGTYPE, OOM, etc.)
Async::Redis::Error::Disconnected # command issued while disconnected (queue full)
```

### Hierarchy

```
Async::Redis::Error (base)
├── ::Connection
├── ::Timeout
├── ::Protocol
├── ::Redis
└── ::Disconnected
```

### Data Integrity Guarantees

1. **FIFO command-response ordering** - Redis guarantees strict FIFO on each connection. We maintain an `@inflight` queue of pending Futures. Each response pops the next Future from the queue. No IDs needed - order is the invariant.

2. **Pipeline failure semantics** - Two distinct failure modes:
   - **Command-level Redis errors** (WRONGTYPE, OOM, NOSCRIPT): Captured inline in result array. Pipeline continues. Each slot contains either data or `Error::Redis` object.
   - **Transport/protocol failures** (connection lost, timeout, malformed RESP): Abort entire pipeline. All remaining slots fail with `Error::Connection` or `Error::Protocol`. Connection reset.

3. **No silent failures** - Every command returns a Future that either resolves with data or fails with typed exception. Never hangs indefinitely (timeouts).

4. **Reconnect safety** - Commands in-flight when connection drops: all pending Futures in `@inflight` fail with `Connection` error. Only queued (not-yet-sent) commands retry on reconnect.

5. **PubSub isolation** - Subscribe mode is modal (RESP2). Regular commands on subscriber connection produce error.

### Connection State Machine

```
┌─────────────────────────────────────────────────────────────────┐
│  RESP2 Normal Mode                                              │
│                                                                  │
│  send(cmd):                                                      │
│    future = Future->new                                          │
│    push @inflight, future                                        │
│    write cmd to socket                                           │
│    return future                                                 │
│                                                                  │
│  recv(response):                                                 │
│    future = shift @inflight    # FIFO pop                        │
│    future->done(response)      # or ->fail if Redis error        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  RESP2 PubSub Mode (modal - entered via SUBSCRIBE)              │
│                                                                  │
│  Allowed commands: SUBSCRIBE, PSUBSCRIBE, UNSUBSCRIBE,          │
│                    PUNSUBSCRIBE, PING, QUIT                      │
│                                                                  │
│  send(SUBSCRIBE channel):                                        │
│    push @inflight, confirmation_future                           │
│    write cmd to socket                                           │
│                                                                  │
│  recv(message):                                                  │
│    if message[0] == 'subscribe':                                 │
│      future = shift @inflight  # confirmation                    │
│      future->done(message)                                       │
│    elsif message[0] == 'message':                                │
│      dispatch to subscription handler  # NOT from @inflight      │
│                                                                  │
│  Other commands → Error::Protocol                                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  RESP3 Mode (future - v2.x)                                     │
│                                                                  │
│  recv(frame):                                                    │
│    if frame.type == '>' (push):                                  │
│      route to push handler     # DON'T consume @inflight         │
│      (pubsub message, invalidation, etc.)                        │
│    else:                                                         │
│      future = shift @inflight  # FIFO pop                        │
│      future->done(frame)                                         │
│                                                                  │
│  Push messages and regular responses can interleave.             │
│  @inflight only tracks request-response pairs.                   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Why FIFO, Not IDs

Redis protocol has no request IDs. Unlike HTTP/2 or WebSockets, you cannot match responses to requests by ID. Redis guarantees:

- Single connection = single stream
- Responses arrive in exact order commands were sent
- This is true even for pipelines

Therefore, a simple queue is correct and sufficient:

```perl
# Correct: FIFO queue
my @inflight;

sub command {
    my ($self, @args) = @_;
    my $future = Future->new;
    push @inflight, $future;
    $self->_send(\@args);
    return $future;
}

sub _on_response {
    my ($self, $response) = @_;
    my $future = shift @inflight;
    if ($response->{type} eq '-') {
        $future->fail(Error::Redis->new($response->{data}));
    } else {
        $future->done($self->_decode($response));
    }
}
```

### Timeout Semantics (Precise Definition)

Timeouts in Redis clients are subtle because:
1. Redis has no request IDs - you can't match a late response to its request
2. Pipelines may receive partial responses before timeout
3. Blocking commands (BLPOP) intentionally wait server-side
4. Socket-level timeouts conflict with request-level timeouts

**Our solution: Per-request deadlines with connection reset on timeout.**

#### Timeout Model

```perl
# Each @inflight entry stores its deadline
push @inflight, {
    future   => $future,
    deadline => time() + $timeout,
    command  => \@args,
};
```

#### The Timeout Timer

A periodic timer (100ms interval) checks for expired requests:

```perl
sub _start_timeout_timer {
    my ($self) = @_;

    $self->{timeout_timer} = IO::Async::Timer::Periodic->new(
        interval => 0.1,  # 100ms
        on_tick => sub { $self->_check_timeouts },
    );
    $loop->add($self->{timeout_timer});
    $self->{timeout_timer}->start;
}

sub _check_timeouts {
    my ($self) = @_;
    my $now = time();

    for my $entry (@{$self->{inflight}}) {
        if ($now >= $entry->{deadline}) {
            # Timeout expired - must reset connection
            $self->_handle_timeout($entry);
            return;  # Connection reset handles all inflight
        }
    }
}
```

#### Critical Rule: Timeout = Reset Connection

When a request times out:

```perl
sub _handle_timeout {
    my ($self, $timed_out_entry) = @_;

    # 1. Fail the timed-out request
    $timed_out_entry->{future}->fail(
        Async::Redis::Error::Timeout->new(
            message => "Request timed out after $self->{request_timeout}s",
            command => $timed_out_entry->{command},
        )
    );

    # 2. Fail ALL pending requests (we lost sync)
    for my $entry (@{$self->{inflight}}) {
        next if $entry->{future}->is_ready;
        $entry->{future}->fail(
            Async::Redis::Error::Connection->new(
                message => "Connection reset due to timeout",
            )
        );
    }
    @{$self->{inflight}} = ();

    # 3. Reset connection (RESP2 has no way to resync)
    $self->_reset_connection;

    # 4. Trigger reconnect if enabled
    $self->_schedule_reconnect if $self->{reconnect};
}
```

**Why reset the entire connection?**

In RESP2, if we read data after a timeout, we have no way to know which request it belongs to. The response stream is now desynchronized. The only safe action is to close the connection and start fresh.

#### Socket Timeout vs Request Timeout

| Type | Purpose | Behavior |
|------|---------|----------|
| `read_timeout` (socket) | Detect dead connections | Coarse-grained; fires if no data at all for N seconds |
| `request_timeout` (per-request) | Authoritative deadline | Each request has its own deadline |

```perl
my $redis = Async::Redis->new(
    read_timeout    => 30,     # Socket-level: "connection seems dead"
    request_timeout => 5,      # Request-level: "this command took too long"
);
```

The socket-level `read_timeout` is a health check - if no data arrives for 30s, the connection is probably broken. The request-level `request_timeout` is the authoritative deadline for individual commands.

**If `request_timeout` fires first:** Request fails, connection resets.
**If `read_timeout` fires first:** Connection fails, all pending requests fail.

Both result in the same outcome: failed requests and connection reset. But `request_timeout` provides more granular control.

#### Blocking Command Deadlines

Blocking commands (BLPOP, BRPOP, BLMOVE) have server-side timeouts:

```perl
# BLPOP with 30 second server timeout
await $redis->blpop('queue', 30);
```

For these commands, the client deadline must account for the server timeout:

```perl
sub _calculate_deadline {
    my ($self, $command, $args) = @_;

    if ($self->_is_blocking_command($command)) {
        # Blocking commands: server_timeout + buffer
        my $server_timeout = $args->[-1];  # Last arg is timeout
        return time() + $server_timeout + $self->{blocking_timeout_buffer};
    }

    # Normal commands: use request_timeout
    return time() + $self->{request_timeout};
}
```

Example with defaults:
```perl
my $redis = Async::Redis->new(
    request_timeout        => 5,     # Normal commands: 5s deadline
    blocking_timeout_buffer => 2,    # Extra 2s for blocking commands
);

# GET 'key' → deadline = now + 5s
# BLPOP 'queue' 30 → deadline = now + 30 + 2 = 32s
```

#### Pipeline Timeout Behavior

Pipelines are atomic from the client's perspective:

```perl
my $pipe = $redis->pipeline;
$pipe->set('a', 1);
$pipe->set('b', 2);
$pipe->get('a');
my $results = await $pipe->execute;  # Single deadline for entire pipeline
```

The pipeline has **one deadline for all commands**. If any command times out, all pending commands in the pipeline fail, and the connection resets.

```perl
sub _execute_pipeline {
    my ($self, $commands) = @_;

    my $future = Future->new;
    my $deadline = time() + $self->{request_timeout};

    # Single @inflight entry for entire pipeline
    push @{$self->{inflight}}, {
        future   => $future,
        deadline => $deadline,
        command  => ['PIPELINE', scalar(@$commands), 'commands'],
        expected_responses => scalar(@$commands),
        responses => [],
    };

    # Send all commands
    $self->_send_pipeline_commands($commands);

    return $future;
}
```

#### Timeout Configuration Summary

```perl
my $redis = Async::Redis->new(
    # Connection establishment
    connect_timeout => 10,          # Max time to establish TCP connection

    # Socket health
    read_timeout  => 30,            # Max silence before assuming dead connection
    write_timeout => 30,            # Max time for write buffer to flush

    # Request deadlines
    request_timeout => 5,           # Default deadline per command
    blocking_timeout_buffer => 2,   # Extra time for blocking commands

    # Per-command override (advanced)
    timeout => {
        'DEBUG SLEEP' => 120,       # Allow long DEBUG SLEEP
        'SLOWLOG'     => 10,        # Server commands get more time
    },
);
```

#### Timeout Summary

| Timeout Fires | Effect |
|---------------|--------|
| connect_timeout | Connection attempt fails, Error::Timeout |
| read_timeout | Connection assumed dead, all inflight fail, reconnect |
| request_timeout | Single request fails, all inflight fail, reset connection |
| blocking command | Uses `server_timeout + buffer` as deadline |
| pipeline | Single deadline for entire pipeline |

**The key insight:** In RESP2, any timeout means connection reset. There's no way to recover sync. This is a fundamental protocol constraint, not a design choice.

### Usage Pattern

```perl
$redis->get('key')->on_fail(sub {
    my ($error) = @_;
    if ($error->isa('Async::Redis::Error::Timeout')) {
        # handle timeout
    } elsif ($error->isa('Async::Redis::Error::Redis')) {
        # handle Redis error (WRONGTYPE, etc.)
    }
});

# Or with try/catch
use Syntax::Keyword::Try;

try {
    my $value = await $redis->get('key');
} catch ($e) {
    warn "Redis error: $e";
}
```

---

## Section 3: Authentication & TLS

### Constructor Options

```perl
my $redis = Async::Redis->new(
    host => 'redis.example.com',
    port => 6380,

    # Authentication
    password => 'secret',              # Redis < 6 (AUTH password)
    username => 'myuser',              # Redis 6+ ACL (AUTH username password)

    # Database selection
    database => 2,                     # SELECT 2 after connect

    # TLS - simple
    tls => 1,                          # enable with defaults

    # TLS - detailed
    tls => {
        ca_file   => '/path/to/ca.crt',
        cert_file => '/path/to/client.crt',
        key_file  => '/path/to/client.key',
        verify    => 1,                # verify server cert (default)
    },
);
```

### Connection Sequence

```
1. TCP connect (or Unix socket)
2. TLS upgrade (if tls => 1)
3. AUTH username password (if credentials provided)
4. SELECT database (if database specified)
5. CLIENT SETNAME (if client_name specified)
6. Connection ready
```

### URI Format

```
redis://[[username:]password@]host[:port][/database]
rediss://...                    # TLS enabled
redis+unix://[:password@]/path/to/socket[?db=N]
```

Examples:
- `redis://localhost` - defaults to port 6379, db 0
- `redis://:secret@localhost:6380/2` - password, custom port, db 2
- `rediss://user:pass@redis.example.com` - TLS with ACL auth
- `redis+unix:///var/run/redis.sock?db=1` - Unix socket

### Reconnect Behavior

- AUTH/SELECT replayed automatically on reconnect
- Same sequence as initial connect
- Credentials stored securely in object (not logged)

### Dependencies

- TLS requires IO::Socket::SSL (optional dependency)
- Without IO::Socket::SSL, `tls => 1` throws error at connect time

### Non-Blocking TLS Handshake (Critical Implementation Detail)

**WARNING:** IO::Socket::SSL's default behavior is blocking. A naive implementation will pass tests on localhost but hang on real networks with latency.

#### The Problem

```perl
# WRONG - These block during handshake!
my $ssl = IO::Socket::SSL->new($socket);
IO::Socket::SSL->start_SSL($socket);  # Also blocks
```

Even with a non-blocking socket, `start_SSL` performs a blocking handshake by default. On localhost this completes instantly, but over a network it can take 50-200ms, blocking the event loop.

#### The Solution: Drive Handshake with Readiness Waiting

```perl
async sub _tls_upgrade {
    my ($self, $socket) = @_;

    # 1. Ensure socket is non-blocking
    $socket->blocking(0);

    # 2. Start SSL without immediate handshake
    IO::Socket::SSL->start_SSL($socket,
        SSL_startHandshake => 0,      # Don't handshake yet!
        SSL_verify_mode    => $self->{tls}{verify} // SSL_VERIFY_PEER,
        SSL_ca_file        => $self->{tls}{ca_file},
        SSL_cert_file      => $self->{tls}{cert_file},
        SSL_key_file       => $self->{tls}{key_file},
    ) or die "SSL setup failed: $SSL_ERROR";

    # 3. Drive handshake with non-blocking loop
    my $deadline = time() + $self->{connect_timeout};

    while (1) {
        # Check timeout
        if (time() >= $deadline) {
            die Async::Redis::Error::Timeout->new(
                message => "TLS handshake timed out",
            );
        }

        # Attempt handshake step
        my $rv = $socket->connect_SSL;

        if ($rv) {
            # Handshake complete!
            return $socket;
        }

        # Handshake needs more I/O
        if ($SSL_ERROR == SSL_WANT_READ) {
            # Wait for socket to become readable
            await Future::IO->waitfor_readable($socket)
                ->timeout($deadline - time());
        }
        elsif ($SSL_ERROR == SSL_WANT_WRITE) {
            # Wait for socket to become writable
            await Future::IO->waitfor_writable($socket)
                ->timeout($deadline - time());
        }
        else {
            # Actual error
            die Async::Redis::Error::Connection->new(
                message => "TLS handshake failed: $SSL_ERROR",
            );
        }
    }
}
```

#### Why This Matters

| Scenario | Blocking Handshake | Non-Blocking Handshake |
|----------|-------------------|------------------------|
| Localhost | ~1ms (seems fine) | ~1ms |
| Same datacenter | 50-100ms **blocks** | 50-100ms async |
| Cross-region | 100-300ms **blocks** | 100-300ms async |
| Slow network | 500ms+ **blocks** | 500ms+ async |
| Packet loss | Retransmits **block** | Retransmits async |

On localhost, everything works. In production, your event loop freezes during every TLS connection.

#### Connection Sequence with TLS

```perl
async sub connect {
    my ($self) = @_;

    # 1. TCP connect (already non-blocking via Future::IO)
    my $socket = await $self->_tcp_connect;

    # 2. TLS upgrade (non-blocking handshake)
    if ($self->{tls}) {
        $socket = await $self->_tls_upgrade($socket);
    }

    # 3. Redis protocol initialization
    await $self->_redis_handshake($socket);  # AUTH, SELECT, etc.

    return $socket;
}
```

#### Testing TLS Non-Blocking Behavior

```perl
# t/10-connection/tls.t

subtest 'TLS handshake does not block event loop' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.01,  # 10ms
        on_tick => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    # Connect to TLS Redis (use remote host, not localhost!)
    my $redis = Async::Redis->new(
        host => $ENV{TLS_REDIS_HOST} // 'redis-tls.example.com',
        port => 6380,
        tls => 1,
        connect_timeout => 5,
    );

    my $start = time();
    await $redis->connect;
    my $elapsed = time() - $start;

    $timer->stop;
    $loop->remove($timer);

    # Timer should have ticked during handshake
    # If handshake took 100ms, we should have ~10 ticks
    my $expected_ticks = int($elapsed / 0.01);
    my $actual_ticks = scalar @ticks;

    ok($actual_ticks >= $expected_ticks * 0.5,
        "Timer ticked $actual_ticks times during ${elapsed}s TLS handshake " .
        "(expected ~$expected_ticks)");
};
```

#### CI/CD Consideration

Localhost TLS tests will pass even with blocking code. For proper verification:

```yaml
# In CI, test against a remote TLS Redis with artificial latency
services:
  redis-tls:
    image: redis:7-alpine
    # Add network latency simulation
    command: >
      sh -c "tc qdisc add dev eth0 root netem delay 50ms &&
             redis-server --tls-port 6380 ..."
```

---

## Section 4: Pipelining

### Basic Pipeline API

```perl
# Build pipeline, execute all at once
my $pipe = $redis->pipeline;
$pipe->set('key1', 'value1');
$pipe->set('key2', 'value2');
$pipe->get('key1');
$pipe->incr('counter');

my $results = await $pipe->execute;
# $results = ['OK', 'OK', 'value1', 1]
```

### Chained Style

```perl
my $results = await $redis->pipeline
    ->set('a', 1)
    ->set('b', 2)
    ->get('a')
    ->get('b')
    ->execute;
```

### Error Handling

**Two distinct failure modes:**

#### 1. Command-Level Redis Errors (Per-Slot)

Redis error replies (WRONGTYPE, OOM, etc.) are captured inline:

```perl
my $results = await $redis->pipeline
    ->set('key', 'value')
    ->incr('key')           # WRONGTYPE error (key is string)
    ->get('key')
    ->execute;

# $results = ['OK', Error::Redis->new(...), 'value']
# Pipeline completed; check each slot for errors
for my $i (0 .. $#$results) {
    if (ref $results->[$i] && $results->[$i]->isa('Async::Redis::Error')) {
        warn "Command $i failed: $results->[$i]";
    }
}
```

#### 2. Transport/Protocol Failures (Abort Pipeline)

Connection loss, timeout, or protocol errors abort the entire pipeline:

```perl
my $results = eval {
    await $redis->pipeline
        ->set('a', 1)
        ->set('b', 2)    # Connection drops here
        ->set('c', 3)
        ->execute;
};

if ($@) {
    # $@ is Error::Connection or Error::Timeout
    # All slots failed, connection reset
    # Cannot determine which commands succeeded
}
```

**Why abort on transport failure?**

After connection loss mid-pipeline, we cannot know:
- Which commands were received by Redis
- Which responses we missed
- Whether our writes were applied

The only safe action is to fail all slots and let the caller retry.

### Behavior

- Commands queued locally until `execute` called
- All commands sent as contiguous byte stream (write_all semantics - full buffer written before reading)
- Responses collected in order
- **Command-level Redis errors**: Captured per-slot, pipeline continues
- **Transport/protocol errors**: Entire pipeline fails, connection reset
- Pipeline object is single-use (cannot re-execute)

---

## Section 5: Transactions

### Basic Transaction

```perl
my $results = await $redis->multi(async sub {
    my ($tx) = @_;
    $tx->incr('counter');
    $tx->get('counter');
    $tx->set('updated', time());
});
# $results = [1, '1', 'OK']
```

### WATCH for Optimistic Locking

```perl
# Watch keys, abort if they change before EXEC
my $results = await $redis->watch_multi(['balance'], async sub {
    my ($tx, $watched) = @_;

    # $watched contains current values of watched keys
    my $balance = $watched->{balance};

    if ($balance >= 100) {
        $tx->decrby('balance', 100);
        $tx->incr('purchases');
    }
});

# Returns undef if WATCH failed (key changed)
# Returns results array if successful
```

### Manual Transaction Control

```perl
await $redis->watch('key1', 'key2');
await $redis->multi;
await $redis->incr('key1');
await $redis->decr('key2');
my $results = await $redis->exec;  # undef if watch failed
await $redis->unwatch;             # clear watches
```

### Behavior

- MULTI queues commands server-side
- EXEC executes atomically
- WATCH enables optimistic locking
- DISCARD aborts transaction
- Nested transactions not supported (Redis limitation)

---

## Section 6: Lua Scripting

### EVAL

```perl
my $result = await $redis->eval(
    'return redis.call("GET", KEYS[1])',
    1,           # number of keys
    'mykey',     # KEYS[1]
);
```

### EVALSHA with Auto-Fallback

```perl
# Load script, get SHA
my $sha = await $redis->script_load($lua_code);

# Execute by SHA (faster, less bandwidth)
my $result = await $redis->evalsha($sha, 1, 'mykey');

# Auto-fallback: tries SHA, falls back to EVAL if NOSCRIPT
my $result = await $redis->evalsha_or_eval(
    $sha,
    $lua_code,
    1,
    'mykey'
);
```

### Script Object Pattern

```perl
# Define reusable script
my $script = $redis->script(<<'LUA');
    local current = redis.call('GET', KEYS[1]) or 0
    local new = current + ARGV[1]
    redis.call('SET', KEYS[1], new)
    return new
LUA

# Execute (auto-loads SHA on first use)
my $result = await $script->call('counter', 10);
```

---

## Section 7: Blocking Commands

### BLPOP / BRPOP

```perl
# Block up to 30 seconds for item
my $result = await $redis->blpop('queue', 30);
# $result = ['queue', 'item'] or undef on timeout

# Multiple queues (priority order)
my $result = await $redis->blpop('high', 'medium', 'low', 10);
```

### Timeout Handling

```perl
# Blocking commands use their own timeout, not read_timeout
# The Redis timeout (last arg) controls server-side blocking
# Client adds small buffer to avoid race conditions

my $redis = Async::Redis->new(
    read_timeout => 30,
    blocking_timeout_buffer => 2,  # extra seconds for blocking commands
);

# blpop('queue', 60) uses 62 second client timeout
```

### BRPOPLPUSH / BLMOVE

```perl
my $item = await $redis->brpoplpush('src', 'dst', 30);
my $item = await $redis->blmove('src', 'dst', 'RIGHT', 'LEFT', 30);
```

---

## Section 8: SCAN Iterators

### Basic SCAN

```perl
# Returns iterator object
my $iter = $redis->scan_iter(match => 'user:*', count => 100);

while (my $keys = await $iter->next) {
    for my $key (@$keys) {
        say $key;
    }
}
```

### HSCAN / SSCAN / ZSCAN

```perl
# Hash fields
my $iter = $redis->hscan_iter('myhash', match => 'field:*');
while (my $pairs = await $iter->next) {
    my %batch = @$pairs;  # field => value pairs
}

# Set members
my $iter = $redis->sscan_iter('myset', match => 'prefix:*');

# Sorted set members with scores
my $iter = $redis->zscan_iter('myzset', match => '*');
while (my $pairs = await $iter->next) {
    # [member, score, member, score, ...]
}
```

### Iterator Behavior

- Cursor managed internally
- Returns batches (not individual items)
- `next` returns undef when iteration complete
- Safe to use during key modifications
- `count` is hint, not guarantee

---

## Section 9: PubSub

### Subscribe API

```perl
# Subscribe returns a Subscription object
my $sub = await $redis->subscribe('channel1', 'channel2');

# Async iterator pattern
while (my $msg = await $sub->next) {
    say "Channel: $msg->{channel}";
    say "Message: $msg->{data}";
}

# Pattern subscribe
my $sub = await $redis->psubscribe('news:*', 'alerts:*');

while (my $msg = await $sub->next) {
    say "Pattern: $msg->{pattern}";   # 'news:*'
    say "Channel: $msg->{channel}";   # 'news:sports'
    say "Message: $msg->{data}";
}
```

### Unsubscribe

```perl
await $sub->unsubscribe('channel1');  # partial unsubscribe
await $sub->unsubscribe;              # all channels, ends iterator
```

### Publish

```perl
# Publish works on any connection (not subscription)
my $num_receivers = await $redis->publish('channel1', 'hello');
```

### Design Decisions

1. **Subscription is modal** - Once subscribed, connection only accepts SUBSCRIBE/UNSUBSCRIBE/PING/PSUBSCRIBE/PUNSUBSCRIBE. Other commands produce error.

2. **Separate connection recommended** - For apps needing both PubSub and regular commands:
   ```perl
   my $redis = Async::Redis->new(...);      # commands
   my $pubsub = Async::Redis->new(...);     # subscriptions
   ```

3. **Reconnect replays subscriptions** - On reconnect, automatically re-subscribes to all active channels/patterns.

4. **Message structure:**
   ```perl
   {
       type    => 'message',      # or 'pmessage', 'smessage'
       channel => 'news:sports',
       pattern => 'news:*',       # only for pmessage
       data    => 'payload',
   }
   ```

### Sharded PubSub (Redis 7+)

```perl
# Sharded subscribe - messages stay within cluster shard
my $sub = await $redis->ssubscribe('channel1', 'channel2');

while (my $msg = await $sub->next) {
    say "Sharded message: $msg->{data}";
}

# Sharded publish
my $num = await $redis->spublish('channel1', 'hello');
```

- Uses SSUBSCRIBE/SPUBLISH instead of SUBSCRIBE/PUBLISH
- Messages routed to shard owning the channel's slot
- Better scalability in Redis Cluster deployments
- Reconnect replays sharded subscriptions too

---

## Section 10: Connection Pool

### Constructor

```perl
my $pool = Async::Redis::Pool->new(
    host     => 'localhost',
    port     => 6379,

    # Pool sizing
    min      => 2,          # keep 2 connections warm
    max      => 10,         # max concurrent connections

    # Timeouts
    acquire_timeout => 5,   # max wait for connection (seconds)
    idle_timeout    => 60,  # close idle connections after 60s

    # Dirty connection handling
    on_dirty => 'destroy',  # 'destroy' (default) or 'cleanup'
    cleanup_timeout => 5,   # max time to clean dirty connection

    # Pass through to connections
    password => 'secret',
    database => 1,
    tls      => 1,
);
```

### Usage Patterns

```perl
# Acquire/release pattern (DANGEROUS - see below)
my $redis = await $pool->acquire;
await $redis->set('foo', 'bar');
$pool->release($redis);

# Scoped pattern (RECOMMENDED - guarantees cleanup)
my $result = await $pool->with(async sub {
    my ($redis) = @_;
    await $redis->incr('counter');
});
# Connection automatically released, even on exception
```

### Pool Statistics

```perl
my $stats = $pool->stats;
# Returns:
# {
#     active    => 3,    # currently in use
#     idle      => 2,    # available in pool
#     waiting   => 0,    # requests waiting for connection
#     total     => 5,    # active + idle
#     destroyed => 12,   # connections destroyed due to dirty state
# }
```

### Connection Cleanliness (Critical)

A connection is **dirty** if any of these are true:

| State | How It Happens | Why It's Dangerous |
|-------|----------------|-------------------|
| `in_multi` | User started MULTI, didn't EXEC/DISCARD | Next user's commands queued in abandoned transaction |
| `watching` | User called WATCH, didn't UNWATCH/EXEC | Next transaction may fail unexpectedly |
| `in_pubsub` | User subscribed, didn't fully unsubscribe | Connection in modal state, commands fail |
| `inflight > 0` | Pending futures exist | Responses may arrive for wrong user |

#### Connection State Tracking

```perl
# Each connection tracks its state
package Async::Redis::Connection;

sub is_dirty {
    my ($self) = @_;
    return 1 if $self->{in_multi};
    return 1 if $self->{watching};
    return 1 if $self->{in_pubsub};
    return 1 if @{$self->{inflight}} > 0;
    return 0;
}

# State updated by commands
sub multi {
    my ($self) = @_;
    $self->{in_multi} = 1;
    return $self->command('MULTI');
}

sub exec {
    my ($self) = @_;
    my $f = $self->command('EXEC');
    $f->on_ready(sub { $self->{in_multi} = 0 });
    return $f;
}

sub discard {
    my ($self) = @_;
    my $f = $self->command('DISCARD');
    $f->on_ready(sub { $self->{in_multi} = 0 });
    return $f;
}

sub watch {
    my ($self, @keys) = @_;
    $self->{watching} = 1;
    return $self->command('WATCH', @keys);
}

sub unwatch {
    my ($self) = @_;
    my $f = $self->command('UNWATCH');
    $f->on_ready(sub { $self->{watching} = 0 });
    return $f;
}

sub subscribe {
    my ($self, @channels) = @_;
    $self->{in_pubsub} = 1;
    # ... subscription logic
}
```

#### Release Validation

```perl
sub release {
    my ($self, $conn) = @_;

    # Check if connection is clean
    if ($conn->is_dirty) {
        $self->{stats}{destroyed}++;

        # Determine if cleanup is even possible
        my $cleanup_allowed = $self->_can_attempt_cleanup($conn);

        if ($cleanup_allowed && $self->{on_dirty} eq 'cleanup') {
            # Attempt cleanup (only for safe states)
            $self->_cleanup_connection($conn)
                ->timeout($self->{cleanup_timeout})
                ->on_done(sub { $self->_return_to_pool($conn) })
                ->on_fail(sub { $conn->destroy; $self->_maybe_create });
        } else {
            # Default: destroy and replace (safe)
            $conn->destroy;
            $self->_maybe_create_replacement;
        }
        return;
    }

    # Clean connection - return to pool
    $self->_return_to_pool($conn);
}

sub _can_attempt_cleanup {
    my ($self, $conn) = @_;

    # NEVER attempt cleanup for these states - always destroy:

    # 1. PubSub mode - UNSUBSCRIBE returns confirmation frames that
    #    must be correctly drained in modal pubsub mode. Any mismatch
    #    is a protocol hazard. Too risky.
    return 0 if $conn->{in_pubsub};

    # 2. Inflight requests - after timeout/reset model we've already
    #    declared the stream desynced. Draining responses that may
    #    never arrive is impossible to do safely.
    return 0 if @{$conn->{inflight} // []} > 0;

    # 3. Connection marked as desynced/broken
    return 0 if $conn->{protocol_error};

    # Cleanup MAY be attempted for these (still risky, but bounded):
    # - in_multi: DISCARD is safe if we're actually in MULTI
    # - watching: UNWATCH is always safe
    return 1 if $conn->{in_multi} || $conn->{watching};

    # Unknown dirty state - don't risk it
    return 0;
}
```

**Cleanup eligibility summary:**

| Dirty State | Cleanup Allowed? | Reason |
|-------------|-----------------|--------|
| `in_multi` | Yes | DISCARD is safe, bounded |
| `watching` | Yes | UNWATCH is always safe |
| `in_pubsub` | **NO** | Modal protocol, confirmation drain hazard |
| `inflight > 0` | **NO** | Responses may never arrive (timeout/reset) |
| `protocol_error` | **NO** | Stream already known-desynced |

#### Cleanup Sequence (Optional, Non-Default, Limited States Only)

If `on_dirty => 'cleanup'` is configured AND `_can_attempt_cleanup` returned true:

```perl
async sub _cleanup_connection {
    my ($self, $conn) = @_;

    # Note: This is only called for in_multi or watching states.
    # PubSub and inflight connections are always destroyed (see _can_attempt_cleanup).

    # Reset transaction state
    if ($conn->{in_multi}) {
        await $conn->command('DISCARD');
        $conn->{in_multi} = 0;
    }

    if ($conn->{watching}) {
        await $conn->command('UNWATCH');
        $conn->{watching} = 0;
    }

    # Verify connection is now clean
    die "Connection still dirty after cleanup" if $conn->is_dirty;

    return $conn;
}
```

**Note:** The previous version attempted to drain inflight responses and exit pubsub mode. This was removed because:
- **Inflight drain** - After a timeout, we've already reset the connection per our timeout model. Waiting for responses that may never arrive is unsafe.
- **PubSub exit** - UNSUBSCRIBE/PUNSUBSCRIBE return confirmation frames that must be consumed correctly. In modal RESP2 pubsub, any mismatch corrupts the stream. The risk exceeds the benefit.

#### Why Destroy Is The Safe Default

| Cleanup Approach | Risk |
|------------------|------|
| DISCARD | Might fail if not actually in MULTI |
| UNWATCH | Safe but extra round-trip |
| UNSUBSCRIBE | Returns confirmations that must be drained |
| Drain inflight | Timeout if responses never arrive |
| **Destroy** | **Zero risk - fresh connection guaranteed clean** |

The cost of destroying is one TCP handshake + AUTH + SELECT. This is negligible compared to the risk of data corruption from a dirty connection.

### Health Check Nuances

The simple "PING before returning" has edge cases:

```perl
sub _health_check {
    my ($self, $conn) = @_;

    # Can't PING a pubsub connection (well, we can, but response differs)
    if ($conn->{in_pubsub}) {
        # Pubsub connections should never be in pool anyway
        $conn->destroy;
        return Future->fail("PubSub connection in pool");
    }

    # PING with short timeout
    return $conn->command('PING')
        ->timeout(1)
        ->then(sub {
            my ($pong) = @_;
            return Future->done($conn) if $pong eq 'PONG';
            return Future->fail("Unexpected PING response: $pong");
        });
}
```

### The `with()` Pattern (Recommended)

The scoped pattern handles all edge cases:

```perl
async sub with {
    my ($self, $code) = @_;

    my $conn = await $self->acquire;
    my $result;
    my $error;

    try {
        $result = await $code->($conn);
    } catch ($e) {
        $error = $e;
    }

    # Always release, even on exception
    # release() handles dirty detection
    $self->release($conn);

    die $error if $error;
    return $result;
}

# Usage - guaranteed safe
await $pool->with(async sub {
    my ($redis) = @_;

    await $redis->watch('balance');
    await $redis->multi;
    await $redis->decrby('balance', 100);
    await $redis->exec;
    # If exception here, connection destroyed (dirty: in_multi)
    # If success, connection clean and returned to pool
});
```

### PubSub and Pools: Don't Mix

**PubSub connections should NOT come from a pool.** They are:
- Long-lived (subscription duration)
- Modal (can't do regular commands)
- Stateful (have active subscriptions)

```perl
# WRONG: Don't use pool for pubsub
my $redis = await $pool->acquire;
await $redis->subscribe('channel');  # Now connection is dirty forever
# ...
$pool->release($redis);  # Will be destroyed

# RIGHT: Dedicated connection for pubsub
my $subscriber = Async::Redis->new(host => 'localhost');
await $subscriber->connect;
my $sub = await $subscriber->subscribe('channel');
# Keep $subscriber alive for duration of subscription
```

### Transactions and Pools

Transactions are fine with pools **if completed properly**:

```perl
# CORRECT: Transaction completes
await $pool->with(async sub {
    my ($redis) = @_;
    await $redis->multi;
    await $redis->incr('a');
    await $redis->incr('b');
    await $redis->exec;  # Clears in_multi flag
});

# DANGEROUS: Exception mid-transaction
await $pool->with(async sub {
    my ($redis) = @_;
    await $redis->multi;
    await $redis->incr('a');
    die "oops";  # Connection dirty: in_multi=1
    # with() releases dirty connection → destroyed
});
```

### Pipeline and Pools: Timing Matters

```perl
# WRONG: Release while pipeline inflight
my $redis = await $pool->acquire;
my $future = $redis->pipeline->set('a', 1)->execute;
$pool->release($redis);  # Released with inflight futures!
await $future;           # Response may be read by different user

# CORRECT: Wait for pipeline to complete
my $redis = await $pool->acquire;
my $results = await $redis->pipeline->set('a', 1)->execute;
$pool->release($redis);  # Safe: no inflight futures

# BEST: Use with() pattern
await $pool->with(async sub {
    my ($redis) = @_;
    return await $redis->pipeline->set('a', 1)->execute;
});
```

### Behavior Summary

- Connections created on demand up to `max`
- Idle connections beyond `min` closed after `idle_timeout`
- Health check (PING) before returning connection from pool
- **Dirty connections destroyed by default** (safest)
- Optional cleanup mode for high-connection-cost environments
- Dead connections removed automatically
- `acquire_timeout` prevents indefinite blocking under load
- Connections inherit all settings (auth, tls, database)
- **PubSub connections should not use pools**
- **Use `with()` pattern for guaranteed cleanup**

---

## Section 11: Command Generation

### Build Process

```
┌─────────────────────────────────────────────────────────────────┐
│  redis-doc/commands.json  ──►  bin/generate-commands  ──►  Commands.pm  │
└─────────────────────────────────────────────────────────────────┘
```

### Source

Commands fetched from: https://github.com/redis/redis-doc/blob/master/commands.json

### Generated Output

```perl
# lib/Future/IO/Redis/Commands.pm (auto-generated)
package Async::Redis::Commands;

use Future::AsyncAwait;

# String commands
async sub get { shift->command('GET', @_) }
async sub set { shift->command('SET', @_) }
async sub append { shift->command('APPEND', @_) }
async sub incr { shift->command('INCR', @_) }
async sub decr { shift->command('DECR', @_) }

# Multi-word commands become snake_case
async sub client_setname { shift->command('CLIENT', 'SETNAME', @_) }
async sub client_getname { shift->command('CLIENT', 'GETNAME', @_) }
async sub cluster_addslots { shift->command('CLUSTER', 'ADDSLOTS', @_) }
async sub config_get { shift->command('CONFIG', 'GET', @_) }
async sub config_set { shift->command('CONFIG', 'SET', @_) }

# Commands needing transformation
async sub hgetall {
    my $self = shift;
    my $arr = await $self->command('HGETALL', @_);
    return { @$arr };  # array -> hash
}

async sub info {
    my $self = shift;
    my $raw = await $self->command('INFO', @_);
    return _parse_info($raw);  # parse into hash
}

1;
```

### Method Naming Convention

| Redis Command | Perl Method |
|---------------|-------------|
| `GET` | `get` |
| `SET` | `set` |
| `CLIENT SETNAME` | `client_setname` |
| `CLUSTER ADDSLOTS` | `cluster_addslots` |
| `CONFIG GET` | `config_get` |
| `CLIENT NO-EVICT` | `client_no_evict` |

### Transformers

Some commands need return value transformation:

| Command | Transformation |
|---------|---------------|
| `HGETALL` | Array -> Hash |
| `INFO` | String -> Parsed Hash |
| `SCAN` | Array -> Iterator object |
| `HSCAN` | Array -> Iterator object |
| `TIME` | Array -> [seconds, microseconds] |

### Build Script Responsibilities

1. Fetch latest commands.json from redis-doc
2. Generate async method for each command
3. Apply transformers for special return types
4. Generate POD documentation per command
5. Track Redis version requirement for each command
6. Handle subcommands (CLIENT, CLUSTER, CONFIG, etc.)
7. **Extract and encode key position metadata** (see Section 11.1)

---

## Section 11.1: Key Extraction Strategy

Key prefixing **cannot** be "transparent to all key arguments" without understanding command structure. Redis commands have keys in various positions:

| Command | Key Position(s) | Complexity |
|---------|-----------------|------------|
| `GET key` | arg 0 | Simple |
| `SET key value` | arg 0 | Simple |
| `MGET key1 key2 key3` | all args | All args are keys |
| `BITOP AND dest src1 src2` | args 1+ | First arg is operation |
| `EVAL script numkeys k1 k2 a1` | Dynamic | Parse `numkeys` |
| `OBJECT ENCODING key` | arg 1 | After subcommand |
| `MIGRATE host port key db timeout` | arg 2 | Middle position |
| `XREAD STREAMS s1 s2 id1 id2` | Complex | Before IDs, count varies |

### Strategy Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│  1. key_specs from commands.json (preferred, Redis 7+)         │
│     ↓ if not available                                          │
│  2. Manual overrides (share/key_overrides.json)                 │
│     ↓ if not in overrides                                       │
│  3. Pattern-based fallbacks (classic command patterns)          │
│     ↓ if unknown command                                        │
│  4. No prefixing (warn in debug mode)                           │
└─────────────────────────────────────────────────────────────────┘
```

### 1. key_specs (Preferred)

Redis 7+ commands.json includes `key_specs` with precise key locations:

```json
{
  "SET": {
    "key_specs": [
      {
        "begin_search": { "type": "index", "spec": { "index": 1 } },
        "find_keys": { "type": "range", "spec": { "lastkey": 0, "keystep": 1, "limit": 0 } }
      }
    ]
  },
  "EVAL": {
    "key_specs": [
      {
        "begin_search": { "type": "index", "spec": { "index": 3 } },
        "find_keys": { "type": "keynum", "spec": { "keynumidx": 2, "firstkey": 0, "keystep": 1 } }
      }
    ]
  }
}
```

The generator parses these specs and generates extraction code:

```perl
# Generated for SET (index-based)
sub _keys_for_set {
    my (@args) = @_;
    return (0);  # arg 0 is key
}

# Generated for MGET (range-based, all args)
sub _keys_for_mget {
    my (@args) = @_;
    return (0 .. $#args);  # all args are keys
}

# Generated for EVAL (keynum-based, dynamic)
sub _keys_for_eval {
    my (@args) = @_;
    my $numkeys = $args[1];  # keynumidx=2, but 0-indexed after command
    return (2 .. 2 + $numkeys - 1);  # keys start at index 2
}
```

### 2. Manual Overrides

For commands without `key_specs` or with incorrect specs:

```json
// share/key_overrides.json
{
  "BITOP": {
    "note": "First arg is operation, rest are keys",
    "keys": { "type": "range", "start": 1, "end": -1 }
  },
  "OBJECT": {
    "subcommands": {
      "ENCODING": { "keys": [1] },
      "FREQ": { "keys": [1] },
      "IDLETIME": { "keys": [1] },
      "REFCOUNT": { "keys": [1] }
    }
  },
  "DEBUG": {
    "note": "DEBUG commands are dangerous, no prefixing",
    "keys": "none"
  },
  "MIGRATE": {
    "note": "key at position 2, or after KEYS keyword",
    "keys": { "type": "custom", "handler": "_keys_for_migrate" }
  }
}
```

### 3. Pattern-Based Fallbacks

For unrecognized commands (modules, future Redis versions):

```perl
# lib/Future/IO/Redis/KeyExtractor.pm

our %FALLBACK_PATTERNS = (
    # Commands where first arg is always key
    qr/^(GET|SET|DEL|EXISTS|EXPIRE|TTL|TYPE|RENAME.*)$/i => sub {
        my (@args) = @_;
        return (0);
    },

    # Commands where all args are keys
    qr/^(MGET|MSET|DEL|EXISTS|TOUCH|UNLINK)$/i => sub {
        my (@args) = @_;
        return (0 .. $#args);
    },

    # Hash commands: first arg is key
    qr/^H(SET|GET|DEL|EXISTS|INCR|KEYS|LEN|MGET|MSET|VALS|GETALL|SCAN)$/i => sub {
        my (@args) = @_;
        return (0);
    },

    # List commands: first arg is key
    qr/^[LR](PUSH|POP|LEN|INDEX|RANGE|SET|TRIM|REM|INSERT|POS)$/i => sub {
        my (@args) = @_;
        return (0);
    },

    # Unknown: no prefixing, warn
    DEFAULT => sub {
        my ($cmd, @args) = @_;
        warn "Unknown command '$cmd': key prefixing skipped" if $ENV{REDIS_DEBUG};
        return ();
    },
);
```

### 4. Commands That Cannot Be Prefixed

Some commands take patterns, not literal keys:

| Command | Why No Prefix |
|---------|---------------|
| `KEYS pattern` | Pattern matching, not literal key |
| `SCAN ... MATCH pattern` | Pattern matching |
| `PSUBSCRIBE pattern` | Channel pattern |
| `SORT ... BY pattern` | Pattern in BY clause |

For these, prefix the pattern itself:

```perl
# User calls:
$redis->keys('user:*');

# With prefix 'myapp:', becomes:
$redis->keys('myapp:user:*');

# Implementation:
sub _prefix_pattern {
    my ($self, $pattern) = @_;
    return $self->{prefix} . $pattern;
}
```

### 5. Dynamic Extraction (EVAL/EVALSHA)

EVAL requires runtime parsing:

```perl
async sub eval {
    my ($self, $script, $numkeys, @keys_and_args) = @_;

    # Apply prefix to exactly $numkeys args
    if ($self->{prefix} && $numkeys > 0) {
        for my $i (0 .. $numkeys - 1) {
            $keys_and_args[$i] = $self->{prefix} . $keys_and_args[$i];
        }
    }

    return await $self->command('EVAL', $script, $numkeys, @keys_and_args);
}

# Usage:
$redis->eval($script, 2, 'key1', 'key2', 'arg1', 'arg2');
# With prefix 'myapp:' → EVAL $script 2 myapp:key1 myapp:key2 arg1 arg2
```

### 6. Complex Commands (XREAD, MIGRATE)

Some commands need custom handlers:

```perl
# XREAD [COUNT n] [BLOCK ms] STREAMS stream1 stream2 id1 id2
sub _keys_for_xread {
    my (@args) = @_;

    # Find STREAMS keyword
    my $streams_idx;
    for my $i (0 .. $#args) {
        if (uc($args[$i]) eq 'STREAMS') {
            $streams_idx = $i;
            last;
        }
    }
    return () unless defined $streams_idx;

    # Keys are between STREAMS and the IDs
    # Number of streams = number of IDs = (remaining args) / 2
    my $remaining = $#args - $streams_idx;
    my $num_streams = $remaining / 2;

    return ($streams_idx + 1 .. $streams_idx + $num_streams);
}

# MIGRATE host port key|"" db timeout [COPY] [REPLACE] [AUTH pw] [KEYS k1 k2]
sub _keys_for_migrate {
    my (@args) = @_;
    my @key_indices;

    # Single key at position 2 (unless empty string for multi-key)
    push @key_indices, 2 if $args[2] ne '';

    # Multi-key after KEYS keyword
    for my $i (0 .. $#args) {
        if (uc($args[$i]) eq 'KEYS') {
            push @key_indices, ($i + 1 .. $#args);
            last;
        }
    }

    return @key_indices;
}
```

### Generated KeyExtractor Module

The build script generates:

```perl
# lib/Future/IO/Redis/KeyExtractor.pm (auto-generated)
package Async::Redis::KeyExtractor;

use strict;
use warnings;

# Generated from commands.json key_specs + overrides
our %KEY_POSITIONS = (
    'GET'     => sub { (0) },
    'SET'     => sub { (0) },
    'MGET'    => sub { (0 .. $#_) },
    'MSET'    => sub { grep { $_ % 2 == 0 } (0 .. $#_) },  # even indices
    'EVAL'    => \&_keys_for_eval,
    'EVALSHA' => \&_keys_for_eval,
    'XREAD'   => \&_keys_for_xread,
    'MIGRATE' => \&_keys_for_migrate,
    # ... 200+ more
);

sub extract_key_indices {
    my ($command, @args) = @_;
    $command = uc($command);

    if (my $extractor = $KEY_POSITIONS{$command}) {
        return $extractor->(@args);
    }

    # Fallback to pattern matching
    return _fallback_extract($command, @args);
}

sub apply_prefix {
    my ($prefix, $command, @args) = @_;
    return @args unless $prefix;

    my @key_indices = extract_key_indices($command, @args);
    for my $i (@key_indices) {
        $args[$i] = $prefix . $args[$i];
    }

    return @args;
}

1;
```

### Usage in Command Method

```perl
# In Async::Redis
sub command {
    my ($self, $cmd, @args) = @_;

    # Apply key prefixing if configured
    if ($self->{prefix}) {
        @args = Async::Redis::KeyExtractor::apply_prefix(
            $self->{prefix}, $cmd, @args
        );
    }

    # ... send command
}
```

### File Structure Update

```
share/
├── commands.json           # Redis command specs (from redis-doc)
└── key_overrides.json      # Manual key position overrides

lib/Future/IO/Redis/
├── Commands.pm             # Auto-generated command methods
└── KeyExtractor.pm         # Auto-generated key extraction logic
```

### Testing Key Extraction

```perl
# t/20-commands/prefix.t

subtest 'simple commands' => sub {
    my $redis = Async::Redis->new(prefix => 'test:');
    # Verify GET key becomes GET test:key
};

subtest 'MSET prefixes even args only' => sub {
    # MSET key1 val1 key2 val2 → MSET test:key1 val1 test:key2 val2
};

subtest 'EVAL prefixes only numkeys keys' => sub {
    # EVAL script 2 k1 k2 arg1 → EVAL script 2 test:k1 test:k2 arg1
};

subtest 'XREAD prefixes streams not IDs' => sub {
    # XREAD STREAMS s1 s2 0 0 → XREAD STREAMS test:s1 test:s2 0 0
};

subtest 'KEYS prefixes pattern' => sub {
    # KEYS user:* → KEYS test:user:*
};

subtest 'unknown command warns and skips prefix' => sub {
    local $ENV{REDIS_DEBUG} = 1;
    # Verify warning emitted, no prefix applied
};
```

---

## File Structure

```
lib/
├── Future/
│   └── IO/
│       ├── Redis.pm                    # Main client, uses Commands role
│       └── Redis/
│           ├── Commands.pm             # Auto-generated command methods
│           ├── KeyExtractor.pm         # Auto-generated key position logic
│           ├── Connection.pm           # Connection state machine
│           ├── Pool.pm                 # Connection pooling
│           ├── Pipeline.pm             # Command pipelining
│           ├── AutoPipeline.pm         # Automatic batching
│           ├── Transaction.pm          # MULTI/EXEC wrapper
│           ├── Subscription.pm         # PubSub subscription object
│           ├── Script.pm               # Lua script wrapper
│           ├── Iterator.pm             # SCAN cursor iterator
│           ├── URI.pm                  # Connection string parser
│           ├── Telemetry.pm            # OpenTelemetry integration
│           ├── Error.pm                # Exception base class
│           └── Error/
│               ├── Connection.pm
│               ├── Timeout.pm
│               ├── Protocol.pm
│               ├── Redis.pm
│               └── Disconnected.pm
bin/
└── generate-commands                   # Build script for Commands.pm + KeyExtractor.pm
share/
├── commands.json                       # Cached Redis command specs (from redis-doc)
└── key_overrides.json                  # Manual key position overrides
```

---

## Dependencies

### Required

- `Future` (core futures)
- `Future::AsyncAwait` (async/await syntax)
- `Future::IO` 0.17+ (async I/O primitives)
- `Protocol::Redis` or `Protocol::Redis::XS` (RESP parsing)

### Optional

- `IO::Socket::SSL` (TLS support)
- `Protocol::Redis::XS` (faster parsing)

### Development

- `Test2::V0` (testing)
- `Docker` / `docker-compose` (Redis instance for tests)

---

## Implementation Methodology

### Core Principle: Prove Non-Blocking at Every Step

This is a **non-blocking Redis client**. Every feature must prove it doesn't block the event loop. This is not optional - it's the entire point of the library.

### The Non-Blocking Test

Every feature implementation MUST include this verification:

```perl
# t/00-nonblocking-proof.t - Run after EVERY change

use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;
my @ticks;

# Timer that ticks every 10ms
my $timer = IO::Async::Timer::Periodic->new(
    interval => 0.01,
    on_tick => sub { push @ticks, Time::HiRes::time() },
);
$loop->add($timer);
$timer->start;

# Run Redis operations for 500ms
my $redis = Async::Redis->new(host => 'localhost');
my $start = Time::HiRes::time();

my $test = async sub {
    await $redis->connect;

    # Mix of operations
    for my $i (1..50) {
        await $redis->set("nb:$i", "value$i");
        await $redis->get("nb:$i");
    }

    # Pipeline
    my $pipe = $redis->pipeline;
    $pipe->set("nb:pipe:$_", $_) for 1..100;
    await $pipe->execute;

    await $redis->del(map { "nb:$_" } 1..50);
    await $redis->del(map { "nb:pipe:$_" } 1..100);
};

$loop->await($test->());

$timer->stop;
my $elapsed = Time::HiRes::time() - $start;

# CRITICAL: Timer must have ticked regularly throughout
# If Redis ops blocked, timer wouldn't tick
my $expected_ticks = int($elapsed / 0.01);
my $actual_ticks = scalar @ticks;
my $tick_ratio = $actual_ticks / $expected_ticks;

ok($tick_ratio > 0.8,
    "Event loop ticked $actual_ticks times (expected ~$expected_ticks, ratio $tick_ratio)");

# Verify ticks were evenly distributed (not bunched at start/end)
if (@ticks >= 10) {
    my $first_half = grep { $_ < $start + $elapsed/2 } @ticks;
    my $second_half = @ticks - $first_half;
    my $balance = $first_half / @ticks;
    ok($balance > 0.3 && $balance < 0.7,
        "Ticks evenly distributed (first half: $first_half, second: $second_half)");
}

done_testing;
```

**If this test fails, the implementation is broken. Stop and fix before continuing.**

### Iterative Development Process

```
┌─────────────────────────────────────────────────────────────────┐
│  For each feature:                                               │
│                                                                  │
│  1. RUN ALL TESTS (establish baseline)                          │
│     └── If failures exist, STOP and fix first                   │
│                                                                  │
│  2. Write tests for the feature                                  │
│     └── Include non-blocking verification                        │
│                                                                  │
│  3. Implement the feature                                        │
│                                                                  │
│  4. Run feature tests                                            │
│     └── If failures, fix and repeat step 4                       │
│                                                                  │
│  5. RUN ALL TESTS (catch regressions)                           │
│     └── If regressions, STOP and fix before continuing          │
│                                                                  │
│  6. Run non-blocking proof test                                  │
│     └── If fails, implementation is wrong - fix before moving on│
│                                                                  │
│  7. Commit with passing tests                                    │
│                                                                  │
│  8. Move to next feature                                         │
└─────────────────────────────────────────────────────────────────┘
```

### Step-by-Step Implementation Plan

Each step follows the process above. Steps are ordered to build on previous work.

#### Step 0: Establish Baseline
```bash
# Verify existing sketch works
prove -l t/
# All 3 tests must pass: 01-basic.t, 02-nonblocking.t, 03-pubsub.t
```

#### Step 1: Error Classes
**Goal:** Typed exceptions for all error conditions

1. Run all tests (baseline)
2. Create `t/01-unit/error.t`
3. Implement `lib/Future/IO/Redis/Error.pm` and subclasses
4. Run `prove -l t/01-unit/error.t`
5. Run all tests (regression check)
6. Run non-blocking proof
7. Commit

**Tests to write:**
- Error class hierarchy
- Stringification
- `isa()` checks for each type

#### Step 2: URI Parsing
**Goal:** Support connection URIs

1. Run all tests
2. Create `t/01-unit/uri.t`
3. Implement `lib/Future/IO/Redis/URI.pm`
4. Run `prove -l t/01-unit/uri.t`
5. Run all tests
6. Run non-blocking proof
7. Commit

**Tests to write:**
- `redis://localhost`
- `redis://localhost:6380`
- `redis://:password@localhost`
- `redis://user:pass@localhost/2`
- `rediss://localhost` (TLS)
- `redis+unix:///var/run/redis.sock`
- Invalid URIs throw

#### Step 3: Timeouts
**Goal:** Two-tier timeout system (socket-level + request-level)

1. Run all tests
2. Create `t/10-connection/timeout.t`
3. Add timeout parameters to constructor (connect, read, write, request, blocking_buffer)
4. Implement socket-level timeouts (Future::IO->timeout)
5. Implement request-level timeout timer (periodic 100ms check)
6. Implement "timeout = reset connection" logic
7. Implement blocking command deadline calculation
8. Run timeout tests
9. Run all tests
10. Run non-blocking proof (CRITICAL - timeouts must not block)
11. Commit

**Tests to write:**
- Connect timeout fires
- Socket-level read timeout fires on silent connection
- Socket-level write timeout fires on blocked write
- Request timeout fires on slow command
- Request timeout resets connection (verifiable via @inflight state)
- All inflight requests fail when one times out
- Blocking command uses server_timeout + buffer
- Pipeline has single deadline for all commands
- Per-command timeout override works
- Timeout throws `Error::Timeout` with command info
- Normal operations still work within timeout

**Non-blocking verification:**
```perl
# Timeout must not block event loop
my $timer_ticked = 0;
$loop->add(IO::Async::Timer::Countdown->new(
    delay => 0.1,
    on_expire => sub { $timer_ticked = 1 },
)->start);

# This should timeout after 0.5s, but timer should tick at 0.1s
my $redis = Async::Redis->new(
    host => '10.255.255.1',  # non-routable, will timeout
    connect_timeout => 0.5,
);
eval { await $redis->connect };

ok($timer_ticked, 'Event loop not blocked during connect timeout');
```

**Request timeout verification:**
```perl
# Verify request timeout resets connection
my $redis = Async::Redis->new(
    host => 'localhost',
    request_timeout => 0.5,  # 500ms
);
await $redis->connect;

# Send DEBUG SLEEP which takes longer than timeout
my $f1 = $redis->command('DEBUG', 'SLEEP', 2);  # 2 second sleep
my $f2 = $redis->get('key');  # This should also fail

# Both should fail with timeout/connection reset
my @errors;
try { await $f1 } catch ($e) { push @errors, $e }
try { await $f2 } catch ($e) { push @errors, $e }

is(scalar(@errors), 2, 'Both inflight requests failed');
ok($errors[0]->isa('Async::Redis::Error::Timeout'), 'First was timeout');
ok($errors[1]->isa('Async::Redis::Error::Connection'), 'Second was connection reset');
```

#### Step 4: Reconnection
**Goal:** Auto-reconnect with exponential backoff

1. Run all tests
2. Create `t/10-connection/reconnect.t`
3. Implement reconnection logic
4. Run reconnect tests
5. Run all tests
6. Run non-blocking proof (reconnection must not block)
7. Commit

**Tests to write:**
- Reconnect after disconnect
- Exponential backoff timing
- Jitter applied
- Max delay respected
- `on_disconnect` callback fires
- `on_connect` callback fires on reconnect
- Commands queued during reconnect
- Queued commands execute after reconnect

**Non-blocking verification:**
```perl
# Reconnection attempts must not block
await $redis->connect;

# Kill connection
$redis->{socket}->close;

# Timer should keep ticking during reconnect attempts
my $ticks = 0;
my $timer = ...; # 10ms timer

# This should reconnect without blocking
await $redis->set('key', 'value');

ok($ticks > 5, 'Event loop not blocked during reconnection');
```

#### Step 5: Authentication
**Goal:** AUTH and SELECT on connect

1. Run all tests
2. Create `t/10-connection/auth.t`
3. Implement AUTH/SELECT in connect sequence
4. Run auth tests (requires redis-auth Docker container)
5. Run all tests
6. Run non-blocking proof
7. Commit

**Tests to write:**
- Password authentication works
- Username + password (ACL) works
- Wrong password throws `Error::Redis`
- SELECT database works
- Auth replayed on reconnect

#### Step 6: TLS
**Goal:** Non-blocking TLS/SSL connections

1. Run all tests
2. Create `t/10-connection/tls.t`
3. Implement non-blocking TLS upgrade:
   - Socket set non-blocking BEFORE start_SSL
   - `SSL_startHandshake => 0` to defer handshake
   - Drive handshake with `connect_SSL` + readiness waiting
   - Loop on SSL_WANT_READ/SSL_WANT_WRITE
   - Respect connect_timeout for entire handshake
4. Run TLS tests (requires redis-tls Docker container)
5. Run all tests
6. Run non-blocking proof (CRITICAL - TLS handshake must not block)
7. Commit

**Tests to write:**
- `tls => 1` enables TLS
- Custom CA/cert/key works
- Certificate verification works
- Invalid cert throws `Error::Connection`
- **TLS handshake does not block event loop** (timer tick test)
- Handshake timeout fires correctly
- Reconnect re-establishes TLS

**Non-blocking verification (CRITICAL):**
```perl
# WARNING: Localhost tests will pass even with blocking code!
# Must test with network latency to catch blocking handshakes.

subtest 'TLS handshake non-blocking' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.01,
        on_tick => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    # Use remote host or add artificial latency
    my $redis = Async::Redis->new(
        host => $ENV{TLS_REDIS_HOST},
        tls => 1,
        connect_timeout => 5,
    );

    my $start = time();
    await $redis->connect;
    my $elapsed = time() - $start;

    $timer->stop;

    # If handshake took 100ms, timer should have ticked ~10 times
    my $expected = int($elapsed / 0.01);
    ok(@ticks >= $expected * 0.5,
        "Event loop ticked during TLS handshake");
};
```

**CI consideration:** Add network latency simulation to catch blocking code that passes on localhost.

#### Step 7: Command Generation
**Goal:** Auto-generate all Redis commands

1. Run all tests
2. Create `bin/generate-commands`
3. Fetch commands.json from redis-doc
4. Generate `lib/Future/IO/Redis/Commands.pm`
5. Create `t/01-unit/commands-generated.t`
6. Run command generation tests
7. Run all tests
8. Run non-blocking proof
9. Commit

**Tests to write:**
- All expected methods exist
- Methods call `->command()` correctly
- snake_case naming correct
- Subcommands work (`client_setname`, etc.)

#### Step 8: Command Tests
**Goal:** Test all command categories

For each category, follow the full process:

1. `t/20-commands/strings.t` - GET, SET, INCR, etc.
2. `t/20-commands/hashes.t` - HSET, HGET, HGETALL, etc.
3. `t/20-commands/lists.t` - LPUSH, RPOP, LRANGE, etc.
4. `t/20-commands/sets.t` - SADD, SMEMBERS, SINTER, etc.
5. `t/20-commands/sorted-sets.t` - ZADD, ZRANGE, ZRANK, etc.
6. `t/20-commands/keys.t` - DEL, EXISTS, EXPIRE, TTL, etc.

Each file must include non-blocking verification.

#### Step 9: Key Extraction & Prefixing
**Goal:** Key position detection and automatic namespace prefixing

1. Run all tests
2. Create `t/01-unit/key-extractor.t` (unit tests, no Redis needed)
3. Create `t/20-commands/prefix.t` (integration tests)
4. Implement `KeyExtractor.pm` with:
   - `key_specs` parsing from commands.json
   - Manual overrides from `key_overrides.json`
   - Pattern-based fallbacks
   - Dynamic extraction for EVAL/EVALSHA
   - Custom handlers for XREAD, MIGRATE, etc.
5. Implement prefix logic in `command()` method
6. Run all tests
7. Run non-blocking proof
8. Commit

**Unit tests (t/01-unit/key-extractor.t):**
- Simple commands: GET, SET return index 0
- Multi-key: MGET returns all indices
- MSET returns even indices only (keys, not values)
- EVAL/EVALSHA parses numkeys dynamically
- BITOP returns indices 1+ (skip operation arg)
- OBJECT subcommands return correct key index
- XREAD finds keys between STREAMS and IDs
- MIGRATE handles single key and KEYS keyword
- Unknown command returns empty (with debug warning)
- Pattern commands (KEYS, SCAN MATCH) prefix pattern

**Integration tests (t/20-commands/prefix.t):**
- Prefix applied to single-key commands
- Prefix applied to multi-key commands (MGET, DEL)
- Prefix NOT applied to values (SET key VALUE)
- Prefix applied to EVAL keys only, not args
- Prefix applied to XREAD streams, not IDs
- Prefix applied to KEYS pattern
- Prefix applied in pipeline commands
- No prefix when prefix option not set
- Empty prefix treated as no prefix

#### Step 10: Transactions
**Goal:** MULTI/EXEC/WATCH support

1. Run all tests
2. Create `t/40-transactions/*.t`
3. Implement `Transaction.pm`
4. Run transaction tests
5. Run all tests
6. Run non-blocking proof
7. Commit

**Tests to write:**
- Basic MULTI/EXEC
- WATCH detects changes
- WATCH conflict returns undef
- DISCARD works
- Nested transaction errors

#### Step 11: Lua Scripting
**Goal:** EVAL/EVALSHA support

1. Run all tests
2. Create `t/60-scripting/*.t`
3. Implement `Script.pm`
4. Run scripting tests
5. Run all tests
6. Run non-blocking proof
7. Commit

#### Step 12: Blocking Commands
**Goal:** BLPOP/BRPOP with proper timeout handling

1. Run all tests
2. Create `t/70-blocking/*.t`
3. Implement blocking command timeout logic
4. Run blocking tests
5. Run all tests
6. Run non-blocking proof (CRITICAL - blocking commands must not block event loop!)
7. Commit

**Non-blocking verification:**
```perl
# BLPOP with 5s timeout must not block event loop
my $ticks = 0;
my $timer = ...; # 10ms timer

# BLPOP on empty list with 1s timeout
my $result = await $redis->blpop('empty:list', 1);

ok($ticks > 50, 'Event loop ticked during BLPOP wait');
is($result, undef, 'BLPOP returned undef on timeout');
```

#### Step 13: SCAN Iterators
**Goal:** Cursor-based iteration

1. Run all tests
2. Create `t/80-scan/*.t`
3. Implement `Iterator.pm`
4. Run SCAN tests
5. Run all tests
6. Run non-blocking proof
7. Commit

#### Step 14: Pipelining Refinement
**Goal:** Error handling, depth limits

1. Run all tests
2. Create `t/30-pipeline/*.t`
3. Refine existing Pipeline implementation
4. Run pipeline tests
5. Run all tests
6. Run non-blocking proof
7. Commit

#### Step 15: Auto-Pipelining
**Goal:** Automatic batching

1. Run all tests
2. Create `t/30-pipeline/auto-pipeline.t`
3. Implement `AutoPipeline.pm`
4. Run auto-pipeline tests
5. Run all tests
6. Run non-blocking proof
7. Commit

**Non-blocking verification:**
```perl
# 1000 commands should batch automatically
my $ticks = 0;
my @futures = map { $redis->set("ap:$_", $_) } (1..1000);
await Future->all(@futures);

ok($ticks > 10, 'Event loop not blocked during 1000 auto-pipelined commands');
```

#### Step 16: PubSub Refinement
**Goal:** Sharded pubsub, reconnect replay

1. Run all tests
2. Create/update `t/50-pubsub/*.t`
3. Implement sharded pubsub, reconnect replay
4. Run pubsub tests
5. Run all tests
6. Run non-blocking proof
7. Commit

#### Step 17: Connection Pool
**Goal:** Pool management with connection cleanliness tracking

1. Run all tests
2. Create `t/90-pool/*.t`
3. Implement connection state tracking (`in_multi`, `watching`, `in_pubsub`, `inflight`)
4. Implement `is_dirty()` check
5. Implement `Pool.pm` with:
   - acquire/release
   - `with()` scoped pattern
   - Health check (PING) on acquire
   - Dirty detection on release
   - `on_dirty => 'destroy'` (default)
   - `on_dirty => 'cleanup'` (optional)
6. Run pool tests
7. Run all tests
8. Run non-blocking proof
9. Commit

**Tests to write:**
- Basic acquire/release
- `with()` pattern works
- `with()` releases even on exception
- Dirty connection (abandoned MULTI) detected and destroyed
- Dirty connection (WATCH without EXEC) detected
- Dirty connection (in pubsub) detected
- Dirty connection (inflight futures) detected
- Cleanup mode resets connection properly
- Destroy mode creates replacement connection
- Stats track destroyed connections
- Health check fails on pubsub connection
- PubSub from pool gets destroyed on release

#### Step 18: Observability
**Goal:** OpenTelemetry, metrics, debug logging

1. Run all tests
2. Create `t/94-observability/*.t`
3. Implement `Telemetry.pm`
4. Run observability tests
5. Run all tests
6. Run non-blocking proof
7. Commit

#### Step 19: Fork Safety
**Goal:** PID tracking for prefork servers

1. Run all tests
2. Create `t/10-connection/fork-safety.t`
3. Implement PID detection in connection
4. Run fork tests
5. Run all tests
6. Run non-blocking proof
7. Commit

#### Step 20: Reliability Testing
**Goal:** Redis restart, network partition, stress tests

1. Run all tests
2. Create `t/91-reliability/*.t`
3. Run reliability tests with Docker
4. Run all tests
5. Run non-blocking proof under stress
6. Commit

#### Step 21: Integration Testing
**Goal:** Full integration, performance benchmarks

1. Run all tests
2. Create `t/99-integration/*.t`
3. Run integration tests
4. Performance benchmark vs Net::Async::Redis
5. 1-hour long-running test
6. Commit

#### Step 22: Documentation & Release
**Goal:** POD, README, CPAN release

1. Run all tests
2. Write comprehensive POD
3. Update README
4. Run all tests one final time
5. Run non-blocking proof one final time
6. Tag release
7. Upload to CPAN

### Regression Policy

**If any test fails after a change:**

1. **STOP** - Do not proceed to next step
2. **Identify** - Which test failed? Is it new or existing?
3. **If existing test failed** - This is a regression. Fix before continuing.
4. **If new test failed** - Fix the implementation
5. **Run ALL tests** - Ensure fix didn't break anything else
6. **Run non-blocking proof** - Ensure fix didn't introduce blocking
7. **Only then continue** to next step

### Continuous Non-Blocking Verification

The non-blocking proof test (`t/00-nonblocking-proof.t`) must be run:

- After every step completion
- Before every commit
- As part of CI pipeline
- Any time you're unsure

**This test is the ultimate arbiter.** If the event loop isn't ticking during Redis operations, the implementation is wrong, regardless of whether other tests pass.

---

## Implementation Phases

### Phase 1: Core Reliability
- Timeouts (connect, read, write)
- Error exception classes
- Typed error handling
- URI connection strings
- Unix socket support

### Phase 2: Reconnection
- Automatic reconnect with backoff
- Connection events (on_connect, on_disconnect)
- Command queuing during reconnect
- CLIENT SETNAME on connect

### Phase 3: Security
- AUTH (password and username/password)
- SELECT database
- TLS support

### Phase 4: Command Generation
- Build script to generate Commands.pm
- Full command coverage from redis-doc
- Transformers for special commands

### Phase 5: Advanced Features
- Pipelining (already sketched, refine)
- Transactions (MULTI/EXEC/WATCH)
- Lua scripting (EVAL/EVALSHA/Script objects)
- Blocking command handling
- SCAN iterators

### Phase 6: Connection Pool
- Pool management (min/max/idle)
- Acquire/release pattern
- Health checking

### Phase 7: Observability
- OpenTelemetry tracing hooks
- Metrics collection
- Debug logging

### Phase 8: Testing & Polish
- Full test suite (see Section 15)
- Edge case handling
- Documentation
- CPAN release

---

## Section 12: Testing Strategy

### Test Categories

```
t/
├── 00-compile.t              # Module compilation
├── 01-unit/                  # Unit tests (no Redis needed)
│   ├── uri.t                 # URI parsing
│   ├── protocol.t            # RESP encoding/decoding
│   ├── error.t               # Exception classes
│   ├── commands-generated.t  # Generated command methods exist
│   └── key-extractor.t       # Key position extraction logic
├── 10-connection/            # Connection tests
│   ├── basic.t               # Connect, disconnect
│   ├── socket-timeout.t      # Socket-level timeouts (connect/read/write)
│   ├── request-timeout.t     # Per-request deadline timeouts
│   ├── timeout-reset.t       # Timeout causes connection reset
│   ├── blocking-timeout.t    # BLPOP/BRPOP deadline calculation
│   ├── reconnect.t           # Auto-reconnection
│   ├── backoff.t             # Exponential backoff timing
│   ├── events.t              # on_connect, on_disconnect, on_error
│   ├── unix-socket.t         # Unix socket connections
│   ├── tls.t                 # TLS/SSL connections
│   ├── auth.t                # AUTH, ACL authentication
│   ├── select.t              # Database selection
│   └── fork-safety.t         # PID tracking after fork
├── 20-commands/              # Command tests
│   ├── strings.t             # GET, SET, INCR, APPEND, etc.
│   ├── lists.t               # LPUSH, RPOP, LRANGE, etc.
│   ├── sets.t                # SADD, SMEMBERS, SINTER, etc.
│   ├── sorted-sets.t         # ZADD, ZRANGE, ZRANK, etc.
│   ├── hashes.t              # HSET, HGET, HGETALL, etc.
│   ├── keys.t                # DEL, EXISTS, EXPIRE, TTL, etc.
│   ├── server.t              # INFO, CONFIG, DBSIZE, etc.
│   └── prefix.t              # Key prefixing for all types
├── 30-pipeline/              # Pipeline tests
│   ├── basic.t               # Pipeline execution
│   ├── chained.t             # Chained API style
│   ├── errors.t              # Per-command error handling
│   ├── large.t               # 1000+ commands in pipeline
│   ├── auto-pipeline.t       # Automatic batching
│   └── depth-limit.t         # Pipeline depth limits
├── 40-transactions/          # Transaction tests
│   ├── multi-exec.t          # Basic MULTI/EXEC
│   ├── watch.t               # WATCH/UNWATCH
│   ├── watch-conflict.t      # WATCH abort on key change
│   ├── discard.t             # DISCARD behavior
│   └── nested.t              # Nested transaction error
├── 50-pubsub/                # PubSub tests
│   ├── subscribe.t           # SUBSCRIBE, UNSUBSCRIBE
│   ├── psubscribe.t          # Pattern subscribe
│   ├── publish.t             # PUBLISH
│   ├── multi-channel.t       # Multiple channels
│   ├── reconnect.t           # Subscription replay on reconnect
│   ├── sharded.t             # SSUBSCRIBE/SPUBLISH (Redis 7+)
│   └── isolation.t           # Commands on subscriber error
├── 60-scripting/             # Lua scripting tests
│   ├── eval.t                # EVAL
│   ├── evalsha.t             # EVALSHA
│   ├── script-load.t         # SCRIPT LOAD
│   ├── auto-fallback.t       # EVALSHA->EVAL fallback
│   └── script-object.t       # Script wrapper pattern
├── 70-blocking/              # Blocking command tests
│   ├── blpop.t               # BLPOP/BRPOP
│   ├── blmove.t              # BLMOVE
│   ├── timeout.t             # Blocking timeout handling
│   └── concurrent.t          # Multiple blocking waiters
├── 80-scan/                  # SCAN iterator tests
│   ├── scan.t                # SCAN
│   ├── hscan.t               # HSCAN
│   ├── sscan.t               # SSCAN
│   ├── zscan.t               # ZSCAN
│   ├── match.t               # Pattern matching
│   └── large.t               # 10000+ keys iteration
├── 90-pool/                  # Connection pool tests
│   ├── basic.t               # Acquire/release
│   ├── scoped.t              # with() pattern
│   ├── sizing.t              # min/max sizing
│   ├── idle.t                # Idle timeout
│   ├── health.t              # Health check on acquire
│   ├── concurrent.t          # Concurrent access
│   ├── exhaustion.t          # Pool exhaustion, acquire_timeout
│   ├── dirty-multi.t         # Dirty detection: abandoned MULTI
│   ├── dirty-watch.t         # Dirty detection: abandoned WATCH
│   ├── dirty-pubsub.t        # Dirty detection: pubsub mode
│   ├── dirty-inflight.t      # Dirty detection: pending futures
│   ├── cleanup-mode.t        # on_dirty => 'cleanup' behavior
│   ├── destroy-mode.t        # on_dirty => 'destroy' behavior (default)
│   └── with-exception.t      # with() handles exceptions correctly
├── 91-reliability/           # Reliability tests
│   ├── redis-restart.t       # Survive Redis restart
│   ├── network-partition.t   # Connection drops mid-command
│   ├── slow-commands.t       # Timeout during slow command
│   ├── memory-pressure.t     # Redis OOM behavior
│   ├── queue-overflow.t      # Command queue limits
│   └── retry.t               # Retry strategy behavior
├── 92-concurrency/           # Concurrency tests
│   ├── parallel-commands.t   # Many concurrent commands
│   ├── parallel-pipelines.t  # Concurrent pipelines
│   ├── parallel-pubsub.t     # Concurrent pub/sub
│   ├── mixed-workload.t      # Commands + pipelines + pubsub
│   └── event-loop.t          # Non-blocking verification
├── 93-binary/                # Binary data tests
│   ├── binary-keys.t         # Binary key names
│   ├── binary-values.t       # Binary values (null bytes)
│   ├── utf8.t                # UTF-8 encoding
│   └── large-values.t        # 1MB+ values
├── 94-observability/         # Observability tests
│   ├── tracing.t             # OpenTelemetry spans
│   ├── metrics.t             # Metrics collection
│   └── debug.t               # Debug logging
└── 99-integration/           # Full integration tests
    ├── pagi-channels.t       # PAGI-Channels use case
    ├── high-throughput.t     # 10000+ ops/sec sustained
    ├── long-running.t        # 1 hour stability test
    └── redis-versions.t      # Redis 6, 7, 8 compatibility
```

### Test Infrastructure

#### Docker Compose for Redis

```yaml
# docker-compose.yml
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    command: redis-server --appendonly yes

  redis-tls:
    image: redis:7-alpine
    ports:
      - "6380:6380"
    volumes:
      - ./certs:/certs:ro
    command: >
      redis-server
      --port 0
      --tls-port 6380
      --tls-cert-file /certs/server.crt
      --tls-key-file /certs/server.key
      --tls-ca-cert-file /certs/ca.crt

  redis-auth:
    image: redis:7-alpine
    ports:
      - "6381:6381"
    command: redis-server --port 6381 --requirepass testpass

  redis-acl:
    image: redis:7-alpine
    ports:
      - "6382:6382"
    command: >
      redis-server --port 6382
      --user testuser on >testpass ~* +@all

  redis-sentinel:
    image: redis:7-alpine
    ports:
      - "26379:26379"
    depends_on:
      - redis
    # Sentinel config here

  redis-cluster:
    # 6-node cluster setup
```

#### Test Helpers

**Important: Test Bootstrap vs Test Body**

| Phase | May Block? | Rationale |
|-------|------------|-----------|
| **Bootstrap** (skip checks, setup) | Yes, briefly | Runs before event loop, practical necessity |
| **Test body** | **NO** | Must prove non-blocking behavior |
| **Cleanup** | Prefer async | Part of test, should maintain discipline |

```perl
# t/lib/Test/Future/IO/Redis.pm
package Test::Async::Redis;

use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

our $loop;

# Initialize event loop (call once at test start)
sub init_loop {
    $loop = IO::Async::Loop->new;
    return $loop;
}

# Skip if no Redis available
# NOTE: This uses ->get which BLOCKS briefly.
# This is acceptable in bootstrap phase only.
# Test bodies must use await, not ->get.
sub skip_without_redis {
    my $redis = eval {
        # BLOCKING - acceptable only in bootstrap
        Async::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        )->connect->get;
    };
    return $redis if $redis;
    skip_all("Redis not available: $@");
}

# Async-friendly skip check (preferred)
# Use when you've already initialized the loop
sub skip_without_redis_async {
    my $redis = Async::Redis->new(
        host => $ENV{REDIS_HOST} // 'localhost',
        connect_timeout => 2,
    );

    my $connected = eval {
        $loop->await($redis->connect);
        1;
    };

    return $redis if $connected;
    skip_all("Redis not available: $@");
}

# Clean up test keys - ASYNC version (preferred)
sub cleanup_keys_async {
    my ($redis, $pattern) = @_;
    return async sub {
        my $keys = await $redis->keys($pattern);
        await $redis->del(@$keys) if @$keys;
    }->();
}

# Test with timeout wrapper
sub with_timeout {
    my ($timeout, $code) = @_;
    my $f = $code->();
    return $f->timeout($timeout);
}

# Assert Future fails with specific error type - ASYNC
sub fails_with_async {
    my ($future, $error_class, $message) = @_;
    my $error;
    eval { $loop->await($future) };
    $error = $@;
    ok($error && $error->isa($error_class), $message);
}

# Async delay - use instead of sleep()!
sub delay {
    my ($seconds) = @_;
    return Future::IO->sleep($seconds);
}

# Async process execution - use instead of system()!
sub run_command_async {
    my (@cmd) = @_;
    require IO::Async::Process;

    my $future = $loop->new_future;
    my $stdout = '';
    my $stderr = '';

    my $process = IO::Async::Process->new(
        command => \@cmd,
        stdout => { into => \$stdout },
        stderr => { into => \$stderr },
        on_finish => sub {
            my ($self, $exitcode) = @_;
            if ($exitcode == 0) {
                $future->done($stdout);
            } else {
                $future->fail("Command failed: $stderr", exitcode => $exitcode);
            }
        },
    );

    $loop->add($process);
    return $future;
}

1;
```

**Usage in tests:**

```perl
# Test file setup
use Test::Async::Redis qw(init_loop skip_without_redis delay run_command_async);

my $loop = init_loop();
my $redis = skip_without_redis();  # Bootstrap - blocking OK here

# Test body - MUST be async
subtest 'my async test' => sub {
    $loop->await(async sub {
        await $redis->set('key', 'value');
        my $result = await $redis->get('key');
        is($result, 'value', 'got expected value');
    }->());
};

# Cleanup - prefer async
$loop->await(cleanup_keys_async($redis, 'test:*'));
```

### Test Scenarios

#### Reliability Tests

```perl
# t/91-reliability/redis-restart.t

use Test2::V0;
use Test::Async::Redis qw(
    init_loop skip_without_redis delay run_command_async
);
use Future::AsyncAwait;

my $loop = init_loop();
my $redis = skip_without_redis();  # Bootstrap - blocking OK

$loop->await(async sub {
    subtest 'survives redis restart' => sub {
        # Set up reconnection
        my $disconnects = 0;
        my $reconnects = 0;

        my $redis = Async::Redis->new(
            host => 'localhost',
            reconnect => 1,
            on_disconnect => sub { $disconnects++ },
            on_connect => sub { $reconnects++ },
        );
        await $redis->connect;

        # Store value
        await $redis->set('test:key', 'before');

        # Simulate Redis restart - ASYNC process execution
        # WRONG: system('docker-compose restart redis');  # BLOCKS!
        # WRONG: sleep(2);  # BLOCKS!
        await run_command_async('docker-compose', 'restart', 'redis');
        await delay(2);  # Async delay - does not block event loop

        # Command should work after reconnect
        my $value = await $redis->get('test:key');
        is($value, 'before', 'value survives restart');
        is($disconnects, 1, 'disconnect detected');
        is($reconnects, 2, 'reconnected (initial + after restart)');
    };
}->());

done_testing;
```

**Common blocking mistakes to avoid:**

```perl
# WRONG - These block the event loop!
sleep(2);                              # Use: await delay(2)
system('docker-compose restart');      # Use: await run_command_async(...)
my $result = $future->get;             # Use: my $result = await $future
                                       #  or: $loop->await($future)

# CORRECT - These are async
await Future::IO->sleep(2);            # Async delay
await run_command_async('docker', 'restart', 'redis');
my $result = await $redis->get('key');
```

#### Concurrency Tests

```perl
# t/92-concurrency/parallel-commands.t

use Test2::V0;
use Test::Async::Redis;
use Future;
use Time::HiRes qw(time);

my $redis = skip_without_redis();

subtest 'parallel commands are truly parallel' => sub {
    my $count = 100;

    # Sequential timing
    my $seq_start = time();
    for my $i (1..$count) {
        await $redis->set("seq:$i", $i);
    }
    my $seq_time = time() - $seq_start;

    # Parallel timing
    my $par_start = time();
    my @futures = map {
        $redis->set("par:$_", $_)
    } (1..$count);
    await Future->all(@futures);
    my $par_time = time() - $par_start;

    # Parallel should be significantly faster
    ok($par_time < $seq_time / 2,
        "parallel ($par_time) < sequential/2 ($seq_time/2)");
};

subtest 'event loop not blocked during commands' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.01,
        on_tick => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    # Run slow command
    await $redis->debug_sleep(0.1);  # 100ms sleep

    $timer->stop;
    $loop->remove($timer);

    # Should have ~10 ticks during the sleep
    ok(@ticks >= 5, "timer ticked " . scalar(@ticks) . " times during Redis sleep");
};

done_testing;
```

#### Edge Case Tests

```perl
# t/93-binary/binary-values.t

use Test2::V0;
use Test::Async::Redis;

my $redis = skip_without_redis();

subtest 'null bytes in values' => sub {
    my $binary = "foo\x00bar\x00baz";
    await $redis->set('binary:null', $binary);
    my $result = await $redis->get('binary:null');
    is($result, $binary, 'null bytes preserved');
};

subtest 'all byte values' => sub {
    my $all_bytes = pack("C*", 0..255);
    await $redis->set('binary:all', $all_bytes);
    my $result = await $redis->get('binary:all');
    is($result, $all_bytes, 'all 256 byte values preserved');
};

subtest 'binary keys' => sub {
    my $key = "key\x00with\xFFbinary";
    await $redis->set($key, 'value');
    my $result = await $redis->get($key);
    is($result, 'value', 'binary key works');
    await $redis->del($key);
};

subtest 'large binary value' => sub {
    my $large = pack("C*", map { $_ % 256 } (1..1_000_000));
    await $redis->set('binary:large', $large);
    my $result = await $redis->get('binary:large');
    is(length($result), 1_000_000, '1MB value preserved');
    is($result, $large, 'content matches');
};

done_testing;
```

### Coverage Requirements

| Category | Minimum Coverage |
|----------|------------------|
| Core modules | 95% |
| Commands.pm | 80% (generated) |
| Error paths | 90% |
| Edge cases | 85% |
| Overall | 90% |

### CI Pipeline

```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        perl: ['5.18', '5.26', '5.34', '5.38']
        redis: ['6.2', '7.0', '7.2', '8.0']

    services:
      redis:
        image: redis:${{ matrix.redis }}-alpine
        ports:
          - 6379:6379

    steps:
      - uses: actions/checkout@v4
      - uses: shogo82148/actions-setup-perl@v1
        with:
          perl-version: ${{ matrix.perl }}

      - name: Install dependencies
        run: cpanm --installdeps --notest .

      - name: Run tests
        run: prove -l -j4 t/
        env:
          REDIS_HOST: localhost

      - name: Run coverage
        run: |
          cpanm Devel::Cover
          cover -test -report codecov

  stress-test:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      # ... setup ...
      - name: Run stress tests
        run: prove -l t/99-integration/
        timeout-minutes: 30

  tls-test:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - name: Generate certs
        run: ./scripts/generate-test-certs.sh
      - name: Start Redis with TLS
        run: docker-compose up -d redis-tls
      - name: Run TLS tests
        run: prove -l t/10-connection/tls.t
```

### Performance Benchmarks

```perl
# benchmark/throughput.pl

use Benchmark qw(:all);
use Async::Redis;
use Net::Async::Redis;
use Mojo::Redis;

my $iterations = 10000;

cmpthese($iterations, {
    'Async::Redis' => sub {
        # our implementation
    },
    'Net::Async::Redis' => sub {
        # comparison
    },
    'Mojo::Redis' => sub {
        # comparison
    },
});

# Target: within 20% of Net::Async::Redis performance
```

### Test Checklist

Before release, ALL must pass:

- [ ] All unit tests pass
- [ ] All integration tests pass with Redis 6.2, 7.0, 7.2, 8.0
- [ ] All tests pass on Perl 5.18, 5.26, 5.34, 5.38
- [ ] TLS tests pass
- [ ] Unix socket tests pass
- [ ] Fork safety tests pass
- [ ] 1-hour long-running test passes
- [ ] 10000 ops/sec throughput achieved
- [ ] Memory usage stable over long run
- [ ] No test flakiness (run 10x)
- [ ] Coverage >= 90%
- [ ] Benchmark within 20% of Net::Async::Redis

---

## Section 13: Observability

### OpenTelemetry Integration

```perl
use OpenTelemetry;

my $redis = Async::Redis->new(
    host => 'localhost',

    # Enable tracing
    otel_tracer => OpenTelemetry->tracer_provider->tracer('redis'),

    # Enable metrics
    otel_meter => OpenTelemetry->meter_provider->meter('redis'),
);
```

### Traces

Each command creates a span:
```
Span: redis.GET
├── db.system: redis
├── db.operation: GET
├── db.statement: GET mykey
├── net.peer.name: localhost
├── net.peer.port: 6379
├── db.redis.database_index: 0
└── duration: 1.2ms
```

### Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `redis.commands.total` | Counter | Commands executed, by command name |
| `redis.commands.duration` | Histogram | Command latency |
| `redis.connections.active` | Gauge | Current active connections |
| `redis.connections.total` | Counter | Total connections created |
| `redis.reconnects.total` | Counter | Reconnection attempts |
| `redis.errors.total` | Counter | Errors by type |
| `redis.pipeline.size` | Histogram | Commands per pipeline |

### Debug Logging

```perl
my $redis = Async::Redis->new(
    debug => 1,                    # log all commands
    debug => sub {                 # custom logger
        my ($direction, $data) = @_;
        # $direction: 'send' or 'recv'
        warn "[$direction] $data\n";
    },
);
```

### Credential & Sensitive Data Redaction

**By default, command arguments are logged, but sensitive commands are redacted:**

| Command | Logged As | Reason |
|---------|-----------|--------|
| `AUTH password` | `AUTH [REDACTED]` | Password exposure |
| `AUTH user pass` | `AUTH user [REDACTED]` | ACL password exposure |
| `CONFIG SET requirepass x` | `CONFIG SET requirepass [REDACTED]` | Password in config |
| `MIGRATE ... AUTH pass` | `MIGRATE ... AUTH [REDACTED]` | Migration password |
| `MIGRATE ... AUTH2 user pass` | `MIGRATE ... AUTH2 user [REDACTED]` | Migration ACL password |

**Implementation:**

```perl
# Redacted commands list (auto-generated from commands.json where applicable)
my %REDACT_COMMANDS = (
    AUTH     => sub { my @a = @_; $a[0] = '[REDACTED]' if @a >= 1; $a[1] = '[REDACTED]' if @a >= 2; @a },
    CONFIG   => sub { my @a = @_; $a[2] = '[REDACTED]' if $a[0] eq 'SET' && $a[1] =~ /pass/i; @a },
    MIGRATE  => \&_redact_migrate_auth,
);

sub _format_command_for_log {
    my ($self, @cmd) = @_;

    my $name = uc($cmd[0] // '');
    my @args = @cmd[1..$#cmd];

    if (my $redactor = $REDACT_COMMANDS{$name}) {
        @args = $redactor->(@args);
    }

    return join(' ', $name, @args);
}
```

**Trace span `db.statement` attribute:**

- **Default**: Redacted (same rules as debug logging)
- **Option**: `otel_include_args => 0` disables command args entirely in traces
- **Option**: `otel_redact => 0` disables redaction (NOT recommended for production)

```perl
my $redis = Async::Redis->new(
    otel_tracer => $tracer,

    # Span db.statement options:
    otel_include_args => 1,        # Include args (default: 1)
    otel_redact       => 1,        # Redact sensitive args (default: 1)
);

# With defaults:
# AUTH command → span.db.statement = "AUTH [REDACTED]"
# GET key      → span.db.statement = "GET key"

# With otel_include_args => 0:
# All commands → span.db.statement = "GET" (command name only)
```

**Key values are NOT logged by default** (they may contain sensitive data):

```perl
# GET sensitive_key → logs "GET sensitive_key" (key name visible)
# Response: "secret123" → logs response size only, not content

# To log response values (dangerous!):
debug => { include_values => 1 }  # NOT recommended
```

**What IS logged by default:**

| Item | Logged | Notes |
|------|--------|-------|
| Command name | Yes | Always visible |
| Key names | Yes | May reveal schema |
| Non-sensitive args | Yes | Counts, ranges, options |
| AUTH passwords | No | Always redacted |
| CONFIG passwords | No | Always redacted |
| Response values | No | Only size/type logged |
| Connection password | No | Never logged anywhere |

---

## Section 14: Binary Data

Redis supports binary-safe strings. Async::Redis handles this correctly:

```perl
# Binary keys and values work
my $binary = pack("C*", 0x00, 0x01, 0xFF, 0xFE);
await $redis->set($binary, $binary);
my $value = await $redis->get($binary);
# $value eq $binary

# UTF-8 strings auto-encoded
await $redis->set('key', 'こんにちは');  # UTF-8 encoded
my $text = await $redis->get('key');
# $text is bytes, decode if needed: decode('UTF-8', $text)
```

### Encoding Policy

- **Input**: Perl strings with UTF-8 flag → encoded to UTF-8 bytes
- **Input**: Byte strings → sent as-is
- **Output**: Always bytes (caller decodes if needed)
- **Keys**: Same rules as values

This matches Redis behavior: everything is bytes.

---

## Future Work (Post-1.0)

These features are explicitly out of scope for initial release but designed for:

### Sentinel Support

```perl
my $redis = Async::Redis->new(
    sentinels => [
        'sentinel1.example.com:26379',
        'sentinel2.example.com:26379',
        'sentinel3.example.com:26379',
    ],
    service => 'mymaster',
);
```

- Query sentinels for master address
- Subscribe to failover notifications
- Automatic reconnect to new master

### Cluster Support

```perl
my $cluster = Async::Redis::Cluster->new(
    nodes => ['node1:7000', 'node2:7001', 'node3:7002'],
);

await $cluster->set('foo', 'bar');  # routes to correct node
```

- Slot-based routing
- MOVED/ASK redirect handling
- Hash tags for co-location

### RESP3 Protocol

See `TODO.md` for comprehensive RESP3 implementation plan.

Summary: RESP3 (Redis 6+) enables inline PubSub, native types, and client-side caching. Requires writing a new parser since none exists on CPAN.

---

## Success Criteria

1. **All tests pass** with real Redis instance
2. **No hangs** - every operation has timeout
3. **Graceful reconnect** - survives Redis restart
4. **PAGI-Channels works** - PubSub reliable under load
5. **API compatible** with Net::Async::Redis naming
6. **Full command coverage** - 200+ Redis commands auto-generated
7. **Transactions work** - MULTI/EXEC/WATCH atomic operations
8. **Pipelining efficient** - 8x+ speedup maintained
9. **TLS works** - secure connections to cloud Redis
10. **Pool works** - connection reuse under concurrent load
11. **Auto-pipelining works** - transparent batching
12. **Key prefixing works** - namespace isolation
13. **Fork-safe** - works with prefork servers (Starman, etc.)
14. **Binary-safe** - handles binary keys/values correctly
15. **Observable** - OpenTelemetry traces/metrics available
