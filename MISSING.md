# Missing Features from Future::IO

This document tracks features that would make building async Redis clients (and similar projects) easier if they existed in Future::IO.

## High Priority

### 1. Connection Lifecycle Events

**Problem:** No built-in way to get notified when a connection is established, disconnected, or errors occur at the socket level.

**Current Workaround:** Manual tracking with wrapper code.

**Desired API:**
```perl
my $conn = Future::IO->connect($socket, $addr,
    on_connect    => sub { ... },
    on_disconnect => sub { ... },
    on_error      => sub { ... },
);
```

### 2. Non-blocking TLS Upgrade

**Problem:** `IO::Socket::SSL->start_SSL()` is blocking. There's no clean async path for upgrading a plain socket to TLS after connection.

**Current Workaround:** Use IO::Async::SSL or handle at socket creation time.

**Desired API:**
```perl
await Future::IO->start_tls($socket, %ssl_options);
```

### 3. Read with Timeout

**Problem:** `Future::IO->read()` doesn't accept a timeout directly. Must compose with `->timeout()` externally.

**Current Workaround:**
```perl
my $data = await Future::IO->read($socket, $len)->timeout($secs);
```

**Desired API:**
```perl
my $data = await Future::IO->read($socket, $len, timeout => 5);
```

### 4. Write with Timeout

**Problem:** Same as read - no built-in timeout for write operations.

**Desired API:**
```perl
await Future::IO->write_exactly($socket, $data, timeout => 5);
```

## Medium Priority

### 5. Later/Next Tick Guarantee

**Problem:** `Future::IO->later` behavior varies by implementation. Sometimes it fires immediately, sometimes on next event loop iteration.

**Desired:** Documented, consistent "run on next event loop tick" behavior across all implementations.

### 6. Connection Pooling Primitives

**Problem:** No standard primitives for connection state tracking (connected, idle, busy).

**Desired API:**
```perl
my $state = Future::IO->connection_state($socket);
# Returns: 'connected', 'disconnecting', 'closed', 'error'
```

### 7. Buffered Reader

**Problem:** Need to manually track read buffers when parsing protocols that may return partial data.

**Current Workaround:** Manual buffer in user code with parser callback.

**Desired API:**
```perl
my $reader = Future::IO->buffered_reader($socket);
my $line = await $reader->read_until("\r\n");
my $bytes = await $reader->read_exactly(1024);
```

## Low Priority

### 8. Unix Domain Socket Helper

**Problem:** Creating Unix domain sockets requires manual Socket.pm usage.

**Desired API:**
```perl
await Future::IO->connect_unix('/var/run/redis.sock');
```

### 9. Reconnection Helper

**Problem:** Reconnection with exponential backoff is common pattern, always reimplemented.

**Desired API:**
```perl
my $conn = await Future::IO->connect_with_retry(
    $socket, $addr,
    max_attempts => 5,
    backoff      => 'exponential',
    base_delay   => 0.1,
    max_delay    => 30,
);
```

### 10. Health Check Pattern

**Problem:** Periodic health checks on idle connections require manual timer setup.

**Desired API:**
```perl
Future::IO->watch_health($socket,
    interval => 30,
    check    => async sub { await ping() },
    on_fail  => sub { reconnect() },
);
```

---

## Implementation Observations (Phase 1)

### Loop->await() vs Future->get()

**Problem:** When using `$loop->await($future)`, the method doesn't throw on Future failure - it just waits. Must call `$future->get` separately to retrieve results and propagate exceptions.

**Current Workaround:**
```perl
my $wait_f = Future->wait_any($operation_f, $timeout_f);
$loop->await($wait_f);
$wait_f->get;  # throws if failed
```

**Observation:** This is confusing behavior. Most Perl async users expect await to throw on failure like Promises do in JavaScript.

### No Future->timeout() Method

**Problem:** The base `Future` class doesn't have a `->timeout()` method. Must use `Future->wait_any()` with a sleep future.

**Current Workaround:**
```perl
my $timeout_f = Future::IO->sleep($seconds)->then(sub {
    return Future->fail('timeout');
});
my $result_f = Future->wait_any($operation_f, $timeout_f);
```

**Desired API:**
```perl
my $result = await $operation_f->timeout($seconds);
```

### waitfor_readable/waitfor_writable Need Timeout Composition

**Problem:** `Future::IO->waitfor_readable()` and `waitfor_writable()` have no timeout parameter. When driving TLS handshakes, must compose timeouts manually.

**Current Workaround:**
```perl
my $read_f = Future::IO->waitfor_readable($socket);
my $timeout_f = Future::IO->sleep($remaining)->then(sub {
    return Future->fail('tls_timeout');
});
my $wait_f = Future->wait_any($read_f, $timeout_f);
await $wait_f;
```

**Desired API:**
```perl
await Future::IO->waitfor_readable($socket, timeout => $remaining);
```

**Observation:** The non-blocking TLS pattern requires repeatedly calling this with timeout in a loop. The boilerplate adds up quickly.

---

## Implementation Observations (Phase 7 - Observability)

### Fork Detection Primitive

**Problem:** No built-in way to detect if the current process has forked. Must track PID manually.

**Current Workaround:**
```perl
my $parent_pid = $$;
# Later...
if ($$ != $parent_pid) {
    # Fork detected, invalidate connection
}
```

**Desired API:**
```perl
Future::IO->on_fork(sub {
    # Called immediately after fork in child process
    # Can invalidate inherited connections
});
```

### Async-Friendly Process Management

**Problem:** Testing fork-related behavior requires `fork()` and `waitpid()` which are blocking. Verifying child behavior requires pipes and manual coordination.

**Observation:** For reliability testing involving process management (restart Redis, network partitions), we need async-friendly helpers that don't block the event loop.

---

## Implementation Observations (Phase 8 - Testing & Polish)

### Async-Friendly External Process Execution

**Problem:** Running external commands (like `docker restart redis`) during tests blocks the event loop. Need to verify async behavior while controlling external services.

**Current Workaround:**
```perl
# Must use IO::Async::Process manually
my $process = IO::Async::Process->new(
    command => ['docker', 'restart', 'redis'],
    on_finish => sub { $future->done(@_) },
);
$loop->add($process);
await $future;
```

**Desired API:**
```perl
my $output = await Future::IO->run_command('docker', 'restart', 'redis');
```

### Tick Counting / Event Loop Verification

**Problem:** No standard way to verify the event loop is actually ticking during async operations. Tests need to prove non-blocking behavior.

**Current Workaround:**
```perl
my @ticks;
my $timer = IO::Async::Timer::Periodic->new(
    interval => 0.01,
    on_tick => sub { push @ticks, time() },
);
$loop->add($timer);
$timer->start;
# ... run operation ...
$timer->stop;
ok(@ticks >= 5, 'event loop ticked');
```

**Desired API:**
```perl
my ($result, $tick_count) = await Future::IO->with_tick_counter(
    $redis->long_operation(),
    interval => 0.01,
);
ok($tick_count >= 5, 'event loop not blocked');
```

### Test Skip with Async Check

**Problem:** Checking if a service is available (Redis, etc.) often requires blocking code during test bootstrap. Want to keep test setup async-friendly.

**Observation:** The split between "bootstrap may block" and "test body must be async" creates cognitive overhead. Would be nice if everything could be consistently async.

---

## Notes

These observations come from building Future::IO::Redis, specifically:

- **Timeouts**: Every Redis operation needs timeout handling. Composing `->timeout()` externally works but is verbose.

- **Connection State**: Pool implementations need to know if a socket is still usable. Currently must track manually.

- **TLS**: Redis supports `STARTTLS` (via `redis://` to `rediss://` upgrade). Non-blocking TLS upgrade would help.

- **Buffering**: RESP protocol parsing requires buffered reads. Currently implemented in Protocol::Redis, but a general-purpose buffered reader would be useful.

- **Event Loop Tick**: Auto-pipelining relies on "flush on next tick" semantics. Consistent behavior across implementations would be helpful.
