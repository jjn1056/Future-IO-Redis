# Async::Redis Production Roadmap

## Current State (v0.001 - Sketch)

Working:
- Basic commands (GET, SET, INCR, DEL, lists)
- Pipelining (8x speedup)
- PUB/SUB (subscribe, publish)
- Non-blocking I/O via Future::IO
- Works with any Future::IO implementation

Missing for production use:
- Everything below

---

## Phase 1: Connection Reliability

### 1.1 Timeouts

```perl
my $redis = Async::Redis->new(
    host => 'localhost',
    connect_timeout => 5,      # seconds
    read_timeout    => 30,
    write_timeout   => 30,
);
```

Implementation:
- Wrap Future::IO calls with `->timeout($seconds)`
- Throw `Timeout` error category

### 1.2 Automatic Reconnection

```perl
my $redis = Async::Redis->new(
    reconnect          => 1,           # enable
    reconnect_interval => 0.5,         # initial delay
    reconnect_max      => 60,          # max delay (exponential backoff)
    reconnect_on_error => sub {        # custom logic
        my ($error) = @_;
        return $error =~ /READONLY/;   # ElastiCache failover
    },
);
```

Implementation:
- Track connection state
- On disconnect/error, schedule reconnect
- Exponential backoff with jitter
- Queue commands during reconnect, replay on success
- Fire `on_disconnect` / `on_connect` events

### 1.3 Connection Events

```perl
my $redis = Async::Redis->new(
    on_connect => sub {
        my ($redis) = @_;
        $redis->select(1);           # switch database
        $redis->client_setname('myapp');
    },
    on_disconnect => sub {
        my ($redis, $reason) = @_;
        warn "Redis disconnected: $reason";
    },
    on_error => sub {
        my ($redis, $error) = @_;
        # log, alert, etc.
    },
);
```

---

## Phase 2: Security

### 2.1 Authentication

```perl
# Simple password (Redis < 6)
my $redis = Async::Redis->new(
    password => 'secret',
);

# ACL (Redis 6+)
my $redis = Async::Redis->new(
    username => 'myuser',
    password => 'secret',
);
```

Implementation:
- Send AUTH on connect (in on_connect handler)
- Re-authenticate on reconnect

### 2.2 TLS/SSL

```perl
my $redis = Async::Redis->new(
    host => 'redis.example.com',
    port => 6380,
    tls  => 1,
    # or detailed:
    tls => {
        ca_file     => '/path/to/ca.crt',
        cert_file   => '/path/to/client.crt',
        key_file    => '/path/to/client.key',
        verify_mode => 1,
    },
);
```

Implementation:
- Use IO::Socket::SSL for TLS upgrade
- Future::IO works with SSL sockets
- Verify certificate by default

---

## Phase 3: High Availability

### 3.1 Sentinel Support

```perl
my $redis = Async::Redis->new(
    sentinels => [
        'sentinel1.example.com:26379',
        'sentinel2.example.com:26379',
        'sentinel3.example.com:26379',
    ],
    service => 'mymaster',
    sentinel_password => 'sentinel_secret',  # optional
);
```

Implementation:
- Query sentinels for master address
- Subscribe to +switch-master channel
- Automatic failover on master change
- Retry different sentinels on failure

### 3.2 Connection Pool

```perl
my $pool = Async::Redis::Pool->new(
    host         => 'localhost',
    min_size     => 2,
    max_size     => 10,
    max_idle     => 60,     # seconds before closing idle
    wait_timeout => 5,      # max wait for connection
);

# Borrow connection
my $redis = await $pool->acquire;
await $redis->set('foo', 'bar');
$pool->release($redis);

# Or with scope guard
await $pool->with_connection(async sub {
    my ($redis) = @_;
    await $redis->set('foo', 'bar');
});
```

---

## Phase 4: Complete Command Coverage

### 4.1 Command Generation

Generate methods from Redis command documentation:

```perl
# Auto-generated from redis-doc JSON
async sub hset {
    my ($self, $key, @field_values) = @_;
    return await $self->command('HSET', $key, @field_values);
}

async sub hget {
    my ($self, $key, $field) = @_;
    return await $self->command('HGET', $key, $field);
}

# ... hundreds more
```

Categories to cover:
- Strings: APPEND, GETRANGE, SETRANGE, MGET, MSET, etc.
- Hashes: HSET, HGET, HMSET, HMGET, HGETALL, HINCRBY, etc.
- Lists: LINDEX, LINSERT, LLEN, LPOS, LREM, LSET, etc.
- Sets: SADD, SREM, SMEMBERS, SINTER, SUNION, SDIFF, etc.
- Sorted Sets: ZADD, ZRANGE, ZRANGEBYSCORE, ZINCRBY, etc.
- Keys: EXISTS, EXPIRE, TTL, RENAME, TYPE, SCAN, etc.
- Server: INFO, CONFIG, DBSIZE, FLUSHDB, etc.

### 4.2 Transactions

```perl
my $results = await $redis->transaction(async sub {
    my ($tx) = @_;
    $tx->incr('counter');
    $tx->get('counter');
    $tx->set('updated', time());
});
# $results = [1, '1', 'OK']

# With WATCH
my $results = await $redis->watch_transaction(['balance'], async sub {
    my ($tx, $watched) = @_;
    my $balance = $watched->{balance};
    if ($balance >= 100) {
        $tx->decrby('balance', 100);
        $tx->incr('purchases');
    }
});
```

### 4.3 Lua Scripting

```perl
# EVAL
my $result = await $redis->eval(
    'return redis.call("GET", KEYS[1])',
    1,           # numkeys
    'mykey',     # KEYS[1]
);

# EVALSHA with auto-fallback
my $sha = await $redis->script_load($lua_code);
my $result = await $redis->evalsha_or_eval($sha, $lua_code, 1, 'mykey');
```

---

## Phase 5: Advanced Features

### 5.1 RESP3 Protocol

```perl
my $redis = Async::Redis->new(
    protocol => 3,  # RESP3
);

# Benefits:
# - Inline PUB/SUB (no separate connection needed)
# - Better type information (maps, sets, booleans)
# - Client-side caching invalidation
```

### 5.2 Streams

```perl
# Producer
await $redis->xadd('mystream', '*', field1 => 'value1');

# Consumer
my $entries = await $redis->xread(
    COUNT => 10,
    BLOCK => 5000,
    STREAMS => 'mystream', '$',
);

# Consumer groups
await $redis->xgroup_create('mystream', 'mygroup', '$', MKSTREAM => 1);
my $entries = await $redis->xreadgroup(
    GROUP => 'mygroup', 'consumer1',
    COUNT => 10,
    STREAMS => 'mystream', '>',
);
await $redis->xack('mystream', 'mygroup', @ids);
```

### 5.3 Cluster Support

```perl
my $cluster = Async::Redis::Cluster->new(
    nodes => [
        'node1.example.com:7000',
        'node2.example.com:7001',
        'node3.example.com:7002',
    ],
);

# Automatic slot routing
await $cluster->set('foo', 'bar');  # Routes to correct node
await $cluster->get('foo');

# Hash tags for co-location
await $cluster->set('{user:1}:name', 'Alice');
await $cluster->set('{user:1}:email', 'alice@example.com');
```

---

## Phase 6: Observability

### 6.1 Metrics

```perl
my $redis = Async::Redis->new(
    metrics => My::Metrics->new,  # interface
);

# Metrics collected:
# - commands_total (counter, by command)
# - command_duration_seconds (histogram)
# - connections_active (gauge)
# - reconnects_total (counter)
# - errors_total (counter, by type)
```

### 6.2 Tracing

```perl
my $redis = Async::Redis->new(
    tracer => My::OpenTelemetry::Tracer->new,
);

# Each command creates a span:
# - span.name: "redis.GET"
# - db.system: "redis"
# - db.statement: "GET mykey"
# - net.peer.name: "localhost"
# - net.peer.port: 6379
```

---

## Implementation Priority

1. **Phase 1.1-1.3**: Connection reliability (essential)
2. **Phase 2.1-2.2**: Security (essential for cloud)
3. **Phase 4.1**: Command coverage (usability)
4. **Phase 3.2**: Connection pool (performance)
5. **Phase 4.2-4.3**: Transactions/Lua (common patterns)
6. **Phase 3.1**: Sentinel (HA deployments)
7. **Phase 5.1**: RESP3 (modern Redis)
8. **Phase 5.2-5.3**: Streams/Cluster (advanced)
9. **Phase 6**: Observability (operations)

---

## File Structure (Target)

```
lib/
├── Future/
│   └── IO/
│       ├── Redis.pm                 # Main client
│       └── Redis/
│           ├── Connection.pm        # Connection management
│           ├── Pool.pm              # Connection pooling
│           ├── Sentinel.pm          # Sentinel support
│           ├── Cluster.pm           # Cluster support
│           ├── Pipeline.pm          # Pipelining
│           ├── Subscription.pm      # PUB/SUB
│           ├── Transaction.pm       # MULTI/EXEC
│           ├── Commands.pm          # Auto-generated commands
│           └── Protocol/
│               ├── RESP2.pm         # RESP2 encoding
│               └── RESP3.pm         # RESP3 encoding
```

---

## Dependencies (Target)

**Required:**
- Future::IO (0.17+)
- Future::AsyncAwait
- Protocol::Redis (or Protocol::Redis::XS)

**Optional:**
- IO::Socket::SSL (for TLS)
- Protocol::Redis::XS (for performance)

**Dev:**
- Test2::V0
- Docker (for integration tests)
