# Future::IO::Redis Production-Ready Design

**Date:** 2026-01-01
**Status:** Approved

---

## Overview

Design for making Future::IO::Redis a production-ready, rock-solid Redis client. Key goals:

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
my $redis = Future::IO::Redis->new(
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
- Key prefixing applied transparently to all key arguments
- Fork safety: detect PID change and create fresh connections (for prefork servers)

### Auto-Pipelining

```perl
my $redis = Future::IO::Redis->new(
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

### Retry Strategies

```perl
my $redis = Future::IO::Redis->new(
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

Retryable errors:
- Connection lost (reconnect first, then retry)
- Timeout (if idempotent command)
- LOADING (Redis still loading dataset)
- BUSY (script in progress)

Non-retryable:
- WRONGTYPE, OOM, NOSCRIPT, AUTH errors
- Write commands (unless explicitly marked idempotent)

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
Future::IO::Redis::Error::Connection   # connect failed, connection lost
Future::IO::Redis::Error::Timeout      # read/write/connect timeout
Future::IO::Redis::Error::Protocol     # malformed RESP, unexpected response
Future::IO::Redis::Error::Redis        # Redis error response (WRONGTYPE, OOM, etc.)
Future::IO::Redis::Error::Disconnected # command issued while disconnected (queue full)
```

### Hierarchy

```
Future::IO::Redis::Error (base)
├── ::Connection
├── ::Timeout
├── ::Protocol
├── ::Redis
└── ::Disconnected
```

### Data Integrity Guarantees

1. **FIFO command-response ordering** - Redis guarantees strict FIFO on each connection. We maintain an `@inflight` queue of pending Futures. Each response pops the next Future from the queue. No IDs needed - order is the invariant.

2. **Pipeline safety** - Pipeline commands sent atomically (single write). Responses read in order, each popping from `@inflight`. Individual command errors captured in results, don't abort pipeline.

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
        Future::IO::Redis::Error::Timeout->new(
            message => "Request timed out after $self->{read_timeout}s",
            command => $timed_out_entry->{command},
        )
    );

    # 2. Fail ALL pending requests (we lost sync)
    for my $entry (@{$self->{inflight}}) {
        next if $entry->{future}->is_ready;
        $entry->{future}->fail(
            Future::IO::Redis::Error::Connection->new(
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
my $redis = Future::IO::Redis->new(
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
my $redis = Future::IO::Redis->new(
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
my $redis = Future::IO::Redis->new(
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
    if ($error->isa('Future::IO::Redis::Error::Timeout')) {
        # handle timeout
    } elsif ($error->isa('Future::IO::Redis::Error::Redis')) {
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
my $redis = Future::IO::Redis->new(
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

```perl
# Individual command errors don't fail the pipeline
my $results = await $redis->pipeline
    ->set('key', 'value')
    ->incr('key')           # WRONGTYPE error
    ->get('key')
    ->execute;

# $results = ['OK', Error::Redis->new(...), 'value']
# Check each result for errors
```

### Behavior

- Commands queued locally until `execute` called
- All commands sent in single write (atomic network operation)
- Responses collected in order
- Individual command errors captured, don't abort pipeline
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

my $redis = Future::IO::Redis->new(
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
   my $redis = Future::IO::Redis->new(...);      # commands
   my $pubsub = Future::IO::Redis->new(...);     # subscriptions
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

## Section 5: Connection Pool

### Constructor

```perl
my $pool = Future::IO::Redis::Pool->new(
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
package Future::IO::Redis::Connection;

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

        if ($self->{on_dirty} eq 'cleanup') {
            # Attempt cleanup (risky but configurable)
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
```

#### Cleanup Sequence (Optional, Non-Default)

If `on_dirty => 'cleanup'` is configured:

```perl
async sub _cleanup_connection {
    my ($self, $conn) = @_;

    # 1. Wait for inflight to drain (with timeout)
    if (@{$conn->{inflight}} > 0) {
        await $self->_drain_inflight($conn, timeout => 2);
    }

    # 2. Reset transaction state
    if ($conn->{in_multi}) {
        await $conn->command('DISCARD');
        $conn->{in_multi} = 0;
    }

    if ($conn->{watching}) {
        await $conn->command('UNWATCH');
        $conn->{watching} = 0;
    }

    # 3. Exit pubsub mode (must unsubscribe from all)
    if ($conn->{in_pubsub}) {
        await $conn->command('UNSUBSCRIBE');
        await $conn->command('PUNSUBSCRIBE');
        # May need to drain subscription confirmations
        $conn->{in_pubsub} = 0;
    }

    return $conn;
}
```

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
my $subscriber = Future::IO::Redis->new(host => 'localhost');
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

## Section 6: Command Generation

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
package Future::IO::Redis::Commands;

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

---

## File Structure

```
lib/
├── Future/
│   └── IO/
│       ├── Redis.pm                    # Main client, uses Commands role
│       └── Redis/
│           ├── Commands.pm             # Auto-generated command methods
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
└── generate-commands                   # Build script for Commands.pm
share/
└── commands.json                       # Cached Redis command specs
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
use Future::IO::Redis;

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
my $redis = Future::IO::Redis->new(host => 'localhost');
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
my $redis = Future::IO::Redis->new(
    host => '10.255.255.1',  # non-routable, will timeout
    connect_timeout => 0.5,
);
eval { await $redis->connect };

ok($timer_ticked, 'Event loop not blocked during connect timeout');
```

**Request timeout verification:**
```perl
# Verify request timeout resets connection
my $redis = Future::IO::Redis->new(
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
ok($errors[0]->isa('Future::IO::Redis::Error::Timeout'), 'First was timeout');
ok($errors[1]->isa('Future::IO::Redis::Error::Connection'), 'Second was connection reset');
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
**Goal:** TLS/SSL connections

1. Run all tests
2. Create `t/10-connection/tls.t`
3. Implement TLS upgrade using IO::Socket::SSL
4. Run TLS tests (requires redis-tls Docker container)
5. Run all tests
6. Run non-blocking proof (TLS handshake must not block)
7. Commit

**Tests to write:**
- `tls => 1` enables TLS
- Custom CA/cert/key works
- Certificate verification works
- Invalid cert throws `Error::Connection`

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

#### Step 9: Key Prefixing
**Goal:** Automatic namespace prefixing

1. Run all tests
2. Create `t/20-commands/prefix.t`
3. Implement prefix logic in `command()` method
4. Run prefix tests
5. Run all tests
6. Run non-blocking proof
7. Commit

**Tests to write:**
- Prefix applied to single-key commands
- Prefix applied to multi-key commands
- Prefix applied in SCAN results
- Prefix NOT applied to non-key args

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

## Section 15: Testing Strategy

### Test Categories

```
t/
├── 00-compile.t              # Module compilation
├── 01-unit/                  # Unit tests (no Redis needed)
│   ├── uri.t                 # URI parsing
│   ├── protocol.t            # RESP encoding/decoding
│   ├── error.t               # Exception classes
│   └── commands-generated.t  # Generated command methods exist
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

```perl
# t/lib/Test/Future/IO/Redis.pm
package Test::Future::IO::Redis;

use strict;
use warnings;
use Test2::V0;
use Future::IO::Redis;

# Skip if no Redis available
sub skip_without_redis {
    my $redis = eval {
        Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        )->connect->get;
    };
    return $redis if $redis;
    skip_all("Redis not available: $@");
}

# Clean up test keys
sub cleanup_keys {
    my ($redis, $pattern) = @_;
    my $keys = $redis->keys($pattern)->get;
    $redis->del(@$keys)->get if @$keys;
}

# Test with timeout wrapper
sub with_timeout {
    my ($timeout, $code) = @_;
    my $f = $code->();
    return $f->timeout($timeout);
}

# Assert Future fails with specific error type
sub fails_with {
    my ($future, $error_class, $message) = @_;
    my $error;
    eval { $future->get };
    $error = $@;
    ok($error && $error->isa($error_class), $message);
}

1;
```

### Test Scenarios

#### Reliability Tests

```perl
# t/91-reliability/redis-restart.t

use Test2::V0;
use Test::Future::IO::Redis;

my $redis = skip_without_redis();

subtest 'survives redis restart' => sub {
    # Set up reconnection
    my $disconnects = 0;
    my $reconnects = 0;

    $redis = Future::IO::Redis->new(
        host => 'localhost',
        reconnect => 1,
        on_disconnect => sub { $disconnects++ },
        on_connect => sub { $reconnects++ },
    );
    await $redis->connect;

    # Store value
    await $redis->set('test:key', 'before');

    # Simulate Redis restart (need Docker control)
    system('docker-compose restart redis');
    sleep(2);  # Wait for restart

    # Command should work after reconnect
    my $value = await $redis->get('test:key');
    is($value, 'before', 'value survives restart');
    is($disconnects, 1, 'disconnect detected');
    is($reconnects, 2, 'reconnected (initial + after restart)');
};

done_testing;
```

#### Concurrency Tests

```perl
# t/92-concurrency/parallel-commands.t

use Test2::V0;
use Test::Future::IO::Redis;
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
use Test::Future::IO::Redis;

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
use Future::IO::Redis;
use Net::Async::Redis;
use Mojo::Redis;

my $iterations = 10000;

cmpthese($iterations, {
    'Future::IO::Redis' => sub {
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

my $redis = Future::IO::Redis->new(
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
my $redis = Future::IO::Redis->new(
    debug => 1,                    # log all commands
    debug => sub {                 # custom logger
        my ($direction, $data) = @_;
        # $direction: 'send' or 'recv'
        warn "[$direction] $data\n";
    },
);
```

---

## Section 14: Binary Data

Redis supports binary-safe strings. Future::IO::Redis handles this correctly:

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
my $redis = Future::IO::Redis->new(
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
my $cluster = Future::IO::Redis::Cluster->new(
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
