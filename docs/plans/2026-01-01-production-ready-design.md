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
| Command coverage | Auto-generate from redis-doc JSON | Matches Net::Async::Redis, stays current with Redis releases |
| Method naming | snake_case (`cluster_addslots`) | Net::Async::Redis compatibility |
| Error handling | Typed exception classes | Clear failure categories, catchable |
| Reconnection | Automatic with exponential backoff | Production resilience |
| TLS | IO::Socket::SSL (optional dep) | Standard Perl TLS solution |

---

## Section 1: Connection Management

### Constructor Options

```perl
my $redis = Future::IO::Redis->new(
    host              => 'localhost',
    port              => 6379,

    # Timeouts (seconds)
    connect_timeout   => 10,
    read_timeout      => 30,
    write_timeout     => 30,

    # Reconnection
    reconnect         => 1,           # enable auto-reconnect
    reconnect_delay   => 0.1,         # initial delay
    reconnect_delay_max => 60,        # max delay (exponential backoff)
    reconnect_jitter  => 0.25,        # randomization factor

    # Events
    on_connect    => sub { my ($redis) = @_; ... },
    on_disconnect => sub { my ($redis, $reason) = @_; ... },
    on_error      => sub { my ($redis, $error) = @_; ... },
);
```

### Behavior

- Commands during disconnect get queued (up to `queue_size` limit)
- On reconnect, AUTH/SELECT replayed automatically
- Exponential backoff: 0.1s -> 0.2s -> 0.4s -> ... -> 60s max
- Jitter prevents thundering herd when many clients reconnect
- `on_disconnect` fires with reason: `connection_lost`, `timeout`, `server_closed`

### Timeout Implementation

```perl
# Wrap Future::IO calls with timeout
my $connect_f = Future::IO->connect($socket, $sockaddr)
    ->timeout($self->{connect_timeout});

my $read_f = Future::IO->read($socket, 65536)
    ->timeout($self->{read_timeout});
```

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

1. **Command-response pairing** - Each command gets a unique ID internally. Responses matched strictly. Mismatch = protocol error, connection reset.

2. **Pipeline safety** - Pipeline commands sent atomically (single write). Responses read in order. Partial failure = entire pipeline fails.

3. **No silent failures** - Every command returns a Future that either resolves with data or fails with typed exception. Never hangs indefinitely (timeouts).

4. **Reconnect safety** - Commands in-flight when connection drops fail with `Connection` error. Only queued (not-yet-sent) commands retry on reconnect.

5. **PubSub isolation** - Subscribe mode uses dedicated connection state. Regular commands on subscriber connection produce error.

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
1. TCP connect
2. TLS upgrade (if tls => 1)
3. AUTH username password (if credentials provided)
4. SELECT database (if database specified)
5. Connection ready
```

### Reconnect Behavior

- AUTH/SELECT replayed automatically on reconnect
- Same sequence as initial connect
- Credentials stored securely in object (not logged)

### Dependencies

- TLS requires IO::Socket::SSL (optional dependency)
- Without IO::Socket::SSL, `tls => 1` throws error at connect time

---

## Section 4: PubSub

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
       type    => 'message',      # or 'pmessage'
       channel => 'news:sports',
       pattern => 'news:*',       # only for pmessage
       data    => 'payload',
   }
   ```

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

    # Pass through to connections
    password => 'secret',
    database => 1,
    tls      => 1,
);
```

### Usage Patterns

```perl
# Acquire/release pattern
my $redis = await $pool->acquire;
await $redis->set('foo', 'bar');
$pool->release($redis);

# Scoped pattern (auto-release, safer)
my $result = await $pool->with(async sub {
    my ($redis) = @_;
    await $redis->incr('counter');
});
```

### Pool Statistics

```perl
my $stats = $pool->stats;
# Returns:
# {
#     active  => 3,    # currently in use
#     idle    => 2,    # available in pool
#     waiting => 0,    # requests waiting for connection
#     total   => 5,    # active + idle
# }
```

### Behavior

- Connections created on demand up to `max`
- Idle connections beyond `min` closed after `idle_timeout`
- Health check (PING) before returning connection from pool
- Dead connections removed automatically
- `acquire_timeout` prevents indefinite blocking under load
- Connections inherit all settings (auth, tls, database)

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
│           ├── Subscription.pm         # PubSub subscription object
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

## Implementation Phases

### Phase 1: Core Reliability
- Timeouts (connect, read, write)
- Error exception classes
- Typed error handling

### Phase 2: Reconnection
- Automatic reconnect with backoff
- Connection events (on_connect, on_disconnect)
- Command queuing during reconnect

### Phase 3: Security
- AUTH (password and username/password)
- SELECT database
- TLS support

### Phase 4: Command Generation
- Build script to generate Commands.pm
- Full command coverage from redis-doc
- Transformers for special commands

### Phase 5: Connection Pool
- Pool management (min/max/idle)
- Acquire/release pattern
- Health checking

### Phase 6: Testing & Polish
- Integration tests with real Redis
- Edge case handling
- Documentation
- CPAN release

---

## Success Criteria

1. **All tests pass** with real Redis instance
2. **No hangs** - every operation has timeout
3. **Graceful reconnect** - survives Redis restart
4. **PAGI-Channels works** - PubSub reliable under load
5. **API compatible** with Net::Async::Redis naming
6. **Full command coverage** - 200+ Redis commands
