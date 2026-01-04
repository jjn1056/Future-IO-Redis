# Async::Redis - TODO

## Current Version: v1.x (RESP2)

The v1.x release implements RESP2 protocol only. This document tracks future enhancements.

---

## RESP3 Protocol Support (v2.x)

### Why RESP3?

RESP3 (Redis 6+) provides significant improvements over RESP2:

| Feature | RESP2 | RESP3 |
|---------|-------|-------|
| PubSub | Dedicated connection | Same connection (push messages) |
| HGETALL result | Array → client converts | Native map type |
| Null values | Special bulk string | Dedicated `_\r\n` type |
| Booleans | Integer 0/1 | Native `#t\r\n` / `#f\r\n` |
| Doubles | String → parse | Native `,3.14\r\n` |
| Client-side caching | Not available | Invalidation messages |
| Sharded PubSub | Not available | Full support |
| Connection count | 2x (command + pubsub) | 1x (shared) |

### The Challenge

**No RESP3 parser exists on CPAN.**

Protocol::Redis only supports RESP2. To implement RESP3, we must either:

1. Write `Protocol::Redis::RESP3` from scratch
2. Extend Protocol::Redis with RESP3 types
3. Write a custom parser in Async::Redis

### RESP3 Type Prefixes

```
+  Simple string    (same as RESP2)
-  Simple error     (same as RESP2)
:  Integer          (same as RESP2)
$  Bulk string      (same as RESP2)
*  Array            (same as RESP2)
_  Null             (NEW)
#  Boolean          (NEW)
,  Double           (NEW)
(  Big number       (NEW)
!  Bulk error       (NEW)
=  Verbatim string  (NEW)
%  Map              (NEW)
~  Set              (NEW)
>  Push             (NEW - for pubsub/invalidation)
|  Attribute        (NEW - metadata)
```

### Implementation Plan

#### Phase 1: RESP3 Parser

```perl
# lib/Future/IO/Redis/Protocol/RESP3.pm

package Async::Redis::Protocol::RESP3;

# Parse RESP3 types
sub parse {
    my ($self, $buffer) = @_;

    my $type = substr($buffer, 0, 1);

    return $self->parse_simple_string($buffer)  if $type eq '+';
    return $self->parse_error($buffer)          if $type eq '-';
    return $self->parse_integer($buffer)        if $type eq ':';
    return $self->parse_bulk_string($buffer)    if $type eq '$';
    return $self->parse_array($buffer)          if $type eq '*';
    return $self->parse_null($buffer)           if $type eq '_';
    return $self->parse_boolean($buffer)        if $type eq '#';
    return $self->parse_double($buffer)         if $type eq ',';
    return $self->parse_big_number($buffer)     if $type eq '(';
    return $self->parse_bulk_error($buffer)     if $type eq '!';
    return $self->parse_verbatim($buffer)       if $type eq '=';
    return $self->parse_map($buffer)            if $type eq '%';
    return $self->parse_set($buffer)            if $type eq '~';
    return $self->parse_push($buffer)           if $type eq '>';
    return $self->parse_attribute($buffer)      if $type eq '|';

    die "Unknown RESP3 type: $type";
}
```

#### Phase 2: Protocol Negotiation

```perl
# On connect, send HELLO 3 to negotiate RESP3
async sub _negotiate_protocol {
    my ($self) = @_;

    if ($self->{protocol} == 3) {
        my $response = await $self->command('HELLO', 3);
        # response is a map with server info
        $self->{server_info} = $response;
        $self->{using_resp3} = 1;
    }
}
```

#### Phase 3: Inline PubSub

With RESP3, push messages arrive on the same connection:

```perl
# Push message handler for inline pubsub
sub _handle_push_message {
    my ($self, $push) = @_;

    my $type = $push->[0];

    if ($type eq 'message') {
        # Regular pubsub message
        $self->_dispatch_pubsub_message($push);
    }
    elsif ($type eq 'invalidate') {
        # Client-side cache invalidation
        $self->_handle_cache_invalidation($push);
    }
    elsif ($type eq 'subscribe' || $type eq 'unsubscribe') {
        # Subscription confirmation
        $self->_handle_subscription_change($push);
    }
}
```

#### Phase 4: Client-Side Caching

```perl
my $redis = Async::Redis->new(
    protocol => 3,
    client_cache => 1,
    cache_size => 10000,  # LRU cache entries
);

# Automatic caching with invalidation
my $value = await $redis->get('key');  # Cached locally
# If 'key' changes on server, invalidation message arrives
# Cache entry automatically removed
```

### API Design

```perl
# Explicit protocol selection
my $redis = Async::Redis->new(
    host => 'localhost',
    protocol => 3,  # Request RESP3
);

# Auto-detect (try RESP3, fall back to RESP2)
my $redis = Async::Redis->new(
    host => 'localhost',
    protocol => 'auto',  # Default in v2.x
);

# Force RESP2 (backward compat)
my $redis = Async::Redis->new(
    host => 'localhost',
    protocol => 2,
);

# Check active protocol
say $redis->protocol_version;  # 2 or 3

# Inline PubSub (RESP3 only)
my $redis = Async::Redis->new(protocol => 3);
await $redis->connect;

# Subscribe on same connection as commands!
$redis->on_message(sub {
    my ($channel, $message) = @_;
    say "Got: $message on $channel";
});
await $redis->subscribe('news');

# Commands still work on same connection
await $redis->set('key', 'value');
```

### Testing Requirements

- [ ] Parse all 14 RESP3 type prefixes
- [ ] HELLO command negotiation
- [ ] Fallback to RESP2 on older Redis
- [ ] Push message handling
- [ ] Inline PubSub works
- [ ] Client-side caching with invalidation
- [ ] Sharded PubSub on same connection
- [ ] Mixed commands + pubsub on same connection
- [ ] Non-blocking verification for push handling

### Dependencies

- Need to write or find RESP3 parser
- Consider: `Protocol::Redis::RESP3` as separate CPAN module?
- Redis 6.0+ for testing

### Estimated Effort

| Component | Effort |
|-----------|--------|
| RESP3 Parser | 2-3 days |
| Protocol negotiation | 1 day |
| Push message handling | 2 days |
| Inline PubSub | 2 days |
| Client-side caching | 3 days |
| Testing | 3 days |
| **Total** | **~2 weeks** |

---

## Other Future Enhancements

### Sentinel Support

```perl
my $redis = Async::Redis->new(
    sentinels => ['sentinel1:26379', 'sentinel2:26379'],
    service => 'mymaster',
);
```

- Query sentinels for master
- Subscribe to failover events
- Auto-reconnect to new master

### Cluster Support

```perl
my $cluster = Async::Redis::Cluster->new(
    nodes => ['node1:7000', 'node2:7001', 'node3:7002'],
);
```

- Slot-based routing
- MOVED/ASK redirect handling
- Hash tags for co-location
- Parallel multi-key operations

### Streams Consumer Groups

Enhanced streams API:

```perl
my $consumer = $redis->consumer_group(
    stream => 'mystream',
    group => 'mygroup',
    consumer => 'consumer1',
);

while (my $entries = await $consumer->read(count => 10, block => 5000)) {
    for my $entry (@$entries) {
        process($entry);
        await $consumer->ack($entry->{id});
    }
}
```

### Observability Enhancements

- Prometheus metrics exporter
- Jaeger/Zipkin tracing integration
- Slow query logging
- Command statistics

---

## Version Roadmap

| Version | Focus | Status |
|---------|-------|--------|
| v1.0 | RESP2, core features, production-ready | In Progress |
| v1.1 | Bug fixes, performance tuning | Planned |
| v2.0 | RESP3 support, inline PubSub | Future |
| v2.1 | Client-side caching | Future |
| v3.0 | Sentinel support | Future |
| v4.0 | Cluster support | Future |

---

## Contributing

See CONTRIBUTING.md for how to help with these features.

Priority contributions needed:
1. RESP3 parser implementation
2. Sentinel integration testing
3. Cluster routing logic
4. Performance benchmarks
