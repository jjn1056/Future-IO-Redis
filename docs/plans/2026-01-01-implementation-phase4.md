# Async::Redis Phase 4: Blocking Commands & SCAN Iterators

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement blocking list/sorted-set commands (BLPOP, BRPOP, BLMOVE, etc.) with proper timeout handling that doesn't block the event loop, and cursor-based SCAN iterators for memory-efficient key/field iteration.

**Architecture:** Blocking commands use server-side timeout + client buffer for deadline calculation. Iterator.pm provides async iterator pattern with internal cursor management for SCAN/HSCAN/SSCAN/ZSCAN.

**Tech Stack:** Perl 5.18+, Future::AsyncAwait, Future::IO

**Prerequisite:** Phases 1-3 complete (connection reliability, commands, transactions, scripting)

---

## Task Overview

| Task | Focus | Files |
|------|-------|-------|
| 12 | Blocking Commands | Timeout logic, `t/70-blocking/*.t` |
| 13 | SCAN Iterators | `lib/Future/IO/Redis/Iterator.pm`, `t/80-scan/*.t` |

---

## Task 12: Blocking Commands (BLPOP, BRPOP, BLMOVE)

**Files:**
- Create: `t/70-blocking/blpop.t`
- Create: `t/70-blocking/brpop.t`
- Create: `t/70-blocking/blmove.t`
- Create: `t/70-blocking/timeout.t`
- Create: `t/70-blocking/concurrent.t`
- Modify: `lib/Future/IO/Redis.pm` (blocking command timeout logic)

### Step 1: Write BLPOP test

```perl
# t/70-blocking/blpop.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('blpop:queue', 'blpop:queue2'));

    subtest 'BLPOP returns immediately when data exists' => sub {
        # Push some data first
        $loop->await($redis->rpush('blpop:queue', 'item1', 'item2'));

        my $start = time();
        my $result = $loop->await($redis->blpop('blpop:queue', 5));
        my $elapsed = time() - $start;

        is($result, ['blpop:queue', 'item1'], 'got first item');
        ok($elapsed < 0.5, "returned immediately (${elapsed}s)");
    };

    subtest 'BLPOP waits for data' => sub {
        # Empty the queue
        $loop->await($redis->del('blpop:queue'));

        # Schedule push after 0.3s
        my $pusher = $loop->delay_future(after => 0.3)->then(sub {
            $redis->rpush('blpop:queue', 'delayed_item');
        });

        my $start = time();
        my $result = $loop->await($redis->blpop('blpop:queue', 5));
        my $elapsed = time() - $start;

        is($result, ['blpop:queue', 'delayed_item'], 'got delayed item');
        ok($elapsed >= 0.2 && $elapsed < 1.0, "waited for item (${elapsed}s)");
    };

    subtest 'BLPOP returns undef on timeout' => sub {
        $loop->await($redis->del('blpop:empty'));

        my $start = time();
        my $result = $loop->await($redis->blpop('blpop:empty', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'BLPOP with multiple queues (priority order)' => sub {
        $loop->await($redis->del('blpop:high', 'blpop:low'));
        $loop->await($redis->rpush('blpop:low', 'low_item'));
        $loop->await($redis->rpush('blpop:high', 'high_item'));

        my $result = $loop->await($redis->blpop('blpop:high', 'blpop:low', 5));
        is($result, ['blpop:high', 'high_item'], 'got from first queue with data');

        $result = $loop->await($redis->blpop('blpop:high', 'blpop:low', 5));
        is($result, ['blpop:low', 'low_item'], 'got from second queue');

        # Cleanup
        $loop->await($redis->del('blpop:high', 'blpop:low'));
    };

    subtest 'BLPOP zero timeout blocks indefinitely' => sub {
        $loop->await($redis->del('blpop:zero'));

        # Schedule push after 0.2s
        my $pusher = $loop->delay_future(after => 0.2)->then(sub {
            $redis->rpush('blpop:zero', 'eventual_item');
        });

        my $start = time();
        my $result = $loop->await($redis->blpop('blpop:zero', 0));
        my $elapsed = time() - $start;

        is($result, ['blpop:zero', 'eventual_item'], 'got item');
        ok($elapsed >= 0.15, "waited for item (${elapsed}s)");

        # Cleanup
        $loop->await($redis->del('blpop:zero'));
    };

    subtest 'non-blocking verification (CRITICAL)' => sub {
        $loop->await($redis->del('blpop:nonblock'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,  # 10ms
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $start = time();
        my $result = $loop->await($redis->blpop('blpop:nonblock', 1));
        my $elapsed = time() - $start;

        $timer->stop;
        $loop->remove($timer);

        is($result, undef, 'BLPOP timed out');
        ok($elapsed >= 0.9, "waited ~1s (${elapsed}s)");

        # CRITICAL: Event loop must tick during BLPOP wait
        # At 10ms intervals over 1 second, we should see ~100 ticks
        # Allow some variance, but must see significant ticking
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times (expected ~100)");
    };

    # Cleanup
    $loop->await($redis->del('blpop:queue', 'blpop:queue2'));
}

done_testing;
```

### Step 2: Run test to verify it fails or check behavior

Run: `prove -l t/70-blocking/blpop.t`
Expected: May pass if basic BLPOP works, but timeout logic needs verification

### Step 3: Write BRPOP test

```perl
# t/70-blocking/brpop.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('brpop:queue'));

    subtest 'BRPOP returns from right side' => sub {
        $loop->await($redis->rpush('brpop:queue', 'first', 'second', 'third'));

        my $result = $loop->await($redis->brpop('brpop:queue', 5));
        is($result, ['brpop:queue', 'third'], 'got rightmost item');

        $result = $loop->await($redis->brpop('brpop:queue', 5));
        is($result, ['brpop:queue', 'second'], 'got next rightmost');
    };

    subtest 'BRPOP waits for data' => sub {
        $loop->await($redis->del('brpop:queue'));

        # Schedule push after 0.3s
        my $pusher = $loop->delay_future(after => 0.3)->then(sub {
            $redis->lpush('brpop:queue', 'delayed');
        });

        my $start = time();
        my $result = $loop->await($redis->brpop('brpop:queue', 5));
        my $elapsed = time() - $start;

        is($result, ['brpop:queue', 'delayed'], 'got delayed item');
        ok($elapsed >= 0.2 && $elapsed < 1.0, "waited for item (${elapsed}s)");
    };

    subtest 'BRPOP returns undef on timeout' => sub {
        $loop->await($redis->del('brpop:empty'));

        my $start = time();
        my $result = $loop->await($redis->brpop('brpop:empty', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'non-blocking verification' => sub {
        $loop->await($redis->del('brpop:nonblock'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $result = $loop->await($redis->brpop('brpop:nonblock', 1));

        $timer->stop;
        $loop->remove($timer);

        is($result, undef, 'BRPOP timed out');
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times");
    };

    # Cleanup
    $loop->await($redis->del('brpop:queue'));
}

done_testing;
```

### Step 4: Write BLMOVE test

```perl
# t/70-blocking/blmove.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Check Redis version supports BLMOVE (6.2+)
    my $info = $loop->await($redis->info('server'));
    my $version = $info->{server}{redis_version} // '0';
    my ($major, $minor) = split /\./, $version;
    skip "BLMOVE requires Redis 6.2+, got $version", 1
        unless ($major > 6 || ($major == 6 && $minor >= 2));

    # Cleanup
    $loop->await($redis->del('blmove:src', 'blmove:dst'));

    subtest 'BLMOVE moves element' => sub {
        $loop->await($redis->rpush('blmove:src', 'a', 'b', 'c'));

        my $result = $loop->await($redis->blmove('blmove:src', 'blmove:dst', 'RIGHT', 'LEFT', 5));
        is($result, 'c', 'moved rightmost element');

        my $src = $loop->await($redis->lrange('blmove:src', 0, -1));
        is($src, ['a', 'b'], 'source has remaining elements');

        my $dst = $loop->await($redis->lrange('blmove:dst', 0, -1));
        is($dst, ['c'], 'destination has moved element');
    };

    subtest 'BLMOVE LEFT RIGHT' => sub {
        $loop->await($redis->del('blmove:src', 'blmove:dst'));
        $loop->await($redis->rpush('blmove:src', 'x', 'y', 'z'));

        my $result = $loop->await($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'RIGHT', 5));
        is($result, 'x', 'moved leftmost element');

        my $dst = $loop->await($redis->lrange('blmove:dst', 0, -1));
        is($dst, ['x'], 'pushed to right of destination');
    };

    subtest 'BLMOVE waits for source data' => sub {
        $loop->await($redis->del('blmove:src', 'blmove:dst'));

        # Schedule push after 0.3s
        my $pusher = $loop->delay_future(after => 0.3)->then(sub {
            $redis->rpush('blmove:src', 'delayed');
        });

        my $start = time();
        my $result = $loop->await($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'LEFT', 5));
        my $elapsed = time() - $start;

        is($result, 'delayed', 'got delayed item');
        ok($elapsed >= 0.2 && $elapsed < 1.0, "waited for item (${elapsed}s)");
    };

    subtest 'BLMOVE returns undef on timeout' => sub {
        $loop->await($redis->del('blmove:src', 'blmove:dst'));

        my $start = time();
        my $result = $loop->await($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'LEFT', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'non-blocking verification' => sub {
        $loop->await($redis->del('blmove:src', 'blmove:dst'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $result = $loop->await($redis->blmove('blmove:src', 'blmove:dst', 'LEFT', 'LEFT', 1));

        $timer->stop;
        $loop->remove($timer);

        is($result, undef, 'BLMOVE timed out');
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times");
    };

    # Cleanup
    $loop->await($redis->del('blmove:src', 'blmove:dst'));
}

done_testing;
```

### Step 5: Write timeout behavior test

```perl
# t/70-blocking/timeout.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(
            host => 'localhost',
            connect_timeout => 2,
            blocking_timeout_buffer => 2,  # 2 second buffer
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'client timeout = server timeout + buffer' => sub {
        $loop->await($redis->del('timeout:queue'));

        # BLPOP with 1 second server timeout
        # Client should wait 1 + 2 = 3 seconds before client-side timeout
        # But server returns first, so we get undef at ~1s

        my $start = time();
        my $result = $loop->await($redis->blpop('timeout:queue', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'BLPOP returned undef');
        # Should be ~1 second (server timeout), not 3 (client timeout)
        ok($elapsed >= 0.9 && $elapsed < 2.0, "server timed out at ${elapsed}s");
    };

    subtest 'blocking_timeout_buffer prevents race condition' => sub {
        # The buffer ensures client doesn't timeout before server response arrives
        # This is hard to test directly, but we can verify the setting is respected

        my $redis_short = Async::Redis->new(
            host => 'localhost',
            blocking_timeout_buffer => 0.5,  # short buffer
        );
        $loop->await($redis_short->connect);

        $loop->await($redis_short->del('timeout:race'));

        my $start = time();
        my $result = $loop->await($redis_short->blpop('timeout:race', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'returned undef');
        # Should still wait for server (~1s), buffer just affects client-side timeout
        ok($elapsed >= 0.9, "waited for server timeout (${elapsed}s)");
    };

    subtest 'BZPOPMIN timeout' => sub {
        $loop->await($redis->del('timeout:zset'));

        my $start = time();
        my $result = $loop->await($redis->bzpopmin('timeout:zset', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'BZPOPMIN returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'BZPOPMAX timeout' => sub {
        $loop->await($redis->del('timeout:zset'));

        my $start = time();
        my $result = $loop->await($redis->bzpopmax('timeout:zset', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'BZPOPMAX returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };

    subtest 'BRPOPLPUSH timeout (deprecated but supported)' => sub {
        $loop->await($redis->del('timeout:src', 'timeout:dst'));

        my $start = time();
        my $result = $loop->await($redis->brpoplpush('timeout:src', 'timeout:dst', 1));
        my $elapsed = time() - $start;

        is($result, undef, 'BRPOPLPUSH returned undef on timeout');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s (${elapsed}s)");
    };
}

done_testing;
```

### Step 6: Write concurrent blocking test

```perl
# t/70-blocking/concurrent.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis1 = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis1;

    # Second connection for concurrent operations
    my $redis2 = Async::Redis->new(host => 'localhost');
    $loop->await($redis2->connect);

    # Third connection for pushing data
    my $pusher = Async::Redis->new(host => 'localhost');
    $loop->await($pusher->connect);

    subtest 'multiple concurrent BLPOP on different queues' => sub {
        $loop->await($redis1->del('conc:q1', 'conc:q2'));

        # Start two BLPOP operations concurrently
        my $f1 = $redis1->blpop('conc:q1', 5);
        my $f2 = $redis2->blpop('conc:q2', 5);

        # Push to both after short delay
        $loop->await($loop->delay_future(after => 0.2));
        $loop->await($pusher->rpush('conc:q1', 'item1'));
        $loop->await($pusher->rpush('conc:q2', 'item2'));

        # Wait for both
        my ($r1, $r2) = $loop->await(Future->all($f1, $f2));

        is($r1, ['conc:q1', 'item1'], 'first BLPOP got item');
        is($r2, ['conc:q2', 'item2'], 'second BLPOP got item');

        # Cleanup
        $loop->await($redis1->del('conc:q1', 'conc:q2'));
    };

    subtest 'multiple BLPOP waiters on same queue (first wins)' => sub {
        $loop->await($redis1->del('conc:shared'));

        # Two connections waiting on same queue
        my $f1 = $redis1->blpop('conc:shared', 5);
        my $f2 = $redis2->blpop('conc:shared', 5);

        # Small delay to ensure both are waiting
        $loop->await($loop->delay_future(after => 0.1));

        # Push one item
        $loop->await($pusher->rpush('conc:shared', 'only_one'));

        # First waiter should get it
        my $r1 = $loop->await($f1);
        is($r1, ['conc:shared', 'only_one'], 'first waiter got the item');

        # Push another for second waiter
        $loop->await($pusher->rpush('conc:shared', 'second_item'));
        my $r2 = $loop->await($f2);
        is($r2, ['conc:shared', 'second_item'], 'second waiter got next item');

        # Cleanup
        $loop->await($redis1->del('conc:shared'));
    };

    subtest 'non-blocking during concurrent waits' => sub {
        $loop->await($redis1->del('conc:nb'));

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Start concurrent BLPOP operations
        my $f1 = $redis1->blpop('conc:nb', 1);
        my $f2 = $redis2->blpop('conc:nb', 1);

        # Wait for both to timeout
        $loop->await(Future->all($f1, $f2));

        $timer->stop;
        $loop->remove($timer);

        # Should tick throughout the concurrent waits
        ok(@ticks >= 50, "Event loop ticked " . scalar(@ticks) . " times during concurrent BLPOPs");
    };
}

done_testing;
```

### Step 7: Verify blocking command timeout logic in Async::Redis

The key implementation is the `_calculate_deadline` and `_is_blocking_command` methods. Verify they exist in `lib/Future/IO/Redis.pm`:

```perl
sub _is_blocking_command {
    my ($self, $cmd) = @_;
    my $uc = uc($cmd);
    return $uc =~ /^(BLPOP|BRPOP|BLMOVE|BRPOPLPUSH|BLMPOP|BZPOPMIN|BZPOPMAX|BZMPOP|XREAD|XREADGROUP)$/;
}

sub _calculate_deadline {
    my ($self, $command, @args) = @_;

    if ($self->_is_blocking_command($command)) {
        # For blocking commands, last arg is server timeout (or second-to-last for some)
        my $server_timeout = $self->_extract_blocking_timeout($command, @args);
        $server_timeout //= 0;

        # Zero timeout = indefinite wait, use very large deadline
        if ($server_timeout == 0) {
            return time() + 86400 * 365;  # 1 year
        }

        return time() + $server_timeout + ($self->{blocking_timeout_buffer} // 2);
    }

    return time() + ($self->{request_timeout} // 5);
}

sub _extract_blocking_timeout {
    my ($self, $cmd, @args) = @_;
    my $uc = uc($cmd);

    # Most blocking commands have timeout as last arg
    if ($uc =~ /^(BLPOP|BRPOP|BZPOPMIN|BZPOPMAX|BRPOPLPUSH)$/) {
        return $args[-1];
    }

    # BLMOVE: src dst LEFT|RIGHT LEFT|RIGHT timeout
    if ($uc eq 'BLMOVE') {
        return $args[-1];
    }

    # XREAD: [COUNT n] [BLOCK ms] STREAMS ...
    # XREADGROUP: GROUP group consumer [COUNT n] [BLOCK ms] ...
    if ($uc =~ /^XREAD/) {
        for my $i (0 .. $#args - 1) {
            if (uc($args[$i]) eq 'BLOCK') {
                return $args[$i + 1] / 1000;  # Convert ms to seconds
            }
        }
        return undef;  # No BLOCK = not blocking
    }

    return $args[-1];  # Default fallback
}
```

### Step 8: Run all blocking tests

Run: `prove -l t/70-blocking/`
Expected: PASS

### Step 9: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 10: Commit

```bash
git add t/70-blocking/ lib/Future/IO/Redis.pm
git commit -m "$(cat <<'EOF'
feat: implement blocking command timeout handling

Blocking commands:
- BLPOP/BRPOP: Block until list has items
- BLMOVE: Atomically move between lists with blocking
- BZPOPMIN/BZPOPMAX: Blocking sorted set pop
- BRPOPLPUSH: Deprecated but supported

Timeout logic:
- Server timeout from command arguments
- Client deadline = server_timeout + blocking_timeout_buffer
- Zero timeout = indefinite wait (1 year deadline)
- XREAD/XREADGROUP: BLOCK arg in milliseconds

Non-blocking verification:
- Event loop ticks 50+ times during 1s BLPOP wait
- Concurrent BLPOP operations work correctly
- Multiple waiters on same queue handled properly

EOF
)"
```

---

## Task 13: SCAN Iterators

**Files:**
- Create: `lib/Future/IO/Redis/Iterator.pm`
- Create: `t/80-scan/scan.t`
- Create: `t/80-scan/hscan.t`
- Create: `t/80-scan/sscan.t`
- Create: `t/80-scan/zscan.t`
- Create: `t/80-scan/match.t`
- Create: `t/80-scan/large.t`
- Modify: `lib/Future/IO/Redis.pm` (add scan_iter methods)

### Step 1: Write basic SCAN test

```perl
# t/80-scan/scan.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Setup test keys
    for my $i (1..20) {
        $loop->await($redis->set("scan:key:$i", "value$i"));
    }

    subtest 'scan_iter returns iterator' => sub {
        my $iter = $redis->scan_iter();
        ok($iter, 'iterator created');
        ok($iter->can('next'), 'iterator has next method');
    };

    subtest 'scan_iter iterates all keys' => sub {
        my $iter = $redis->scan_iter(match => 'scan:key:*');

        my @all_keys;
        while (my $batch = $loop->await($iter->next)) {
            push @all_keys, @$batch;
        }

        is(scalar @all_keys, 20, 'found all 20 keys');

        my %unique = map { $_ => 1 } @all_keys;
        is(scalar keys %unique, 20, 'all keys unique');
    };

    subtest 'scan_iter with count hint' => sub {
        my $iter = $redis->scan_iter(match => 'scan:key:*', count => 5);

        my @batches;
        while (my $batch = $loop->await($iter->next)) {
            push @batches, $batch;
        }

        ok(@batches >= 1, 'got batches');

        my @all = map { @$_ } @batches;
        is(scalar @all, 20, 'found all 20 keys across batches');
    };

    subtest 'scan_iter next returns undef when done' => sub {
        my $iter = $redis->scan_iter(match => 'scan:nonexistent:*');

        my $batch = $loop->await($iter->next);
        # Either empty batch or undef
        ok(!$batch || @$batch == 0, 'no keys found');

        # Subsequent calls return undef
        $batch = $loop->await($iter->next);
        is($batch, undef, 'iterator exhausted');
    };

    subtest 'scan_iter is restartable via reset' => sub {
        my $iter = $redis->scan_iter(match => 'scan:key:*');

        # Consume part of iteration
        my $batch1 = $loop->await($iter->next);
        ok($batch1, 'got first batch');

        # Reset
        $iter->reset;

        # Should start over
        my @all_keys;
        while (my $batch = $loop->await($iter->next)) {
            push @all_keys, @$batch;
        }

        is(scalar @all_keys, 20, 'reset allowed full re-iteration');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $iter = $redis->scan_iter(match => 'scan:key:*', count => 2);
        my @all;
        while (my $batch = $loop->await($iter->next)) {
            push @all, @$batch;
        }

        $timer->stop;
        $loop->remove($timer);

        is(scalar @all, 20, 'got all keys');
        ok(@ticks >= 1, "Event loop ticked during SCAN iteration");
    };

    # Cleanup
    for my $i (1..20) {
        $loop->await($redis->del("scan:key:$i"));
    }
}

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/80-scan/scan.t`
Expected: FAIL (Iterator.pm not implemented)

### Step 3: Write Iterator.pm

```perl
# lib/Future/IO/Redis/Iterator.pm
package Async::Redis::Iterator;

use strict;
use warnings;
use 5.018;

use Future::AsyncAwait;

sub new {
    my ($class, %args) = @_;

    return bless {
        redis   => $args{redis},
        command => $args{command} // 'SCAN',
        key     => $args{key},        # For HSCAN/SSCAN/ZSCAN
        match   => $args{match},
        count   => $args{count},
        type    => $args{type},       # For SCAN TYPE filter
        cursor  => 0,
        done    => 0,
    }, $class;
}

async sub next {
    my ($self) = @_;

    # Already exhausted
    return undef if $self->{done};

    my @args;

    # Build command args based on scan type
    if ($self->{command} eq 'SCAN') {
        @args = ($self->{cursor});
    }
    else {
        # HSCAN, SSCAN, ZSCAN take key first, then cursor
        @args = ($self->{key}, $self->{cursor});
    }

    # Add MATCH pattern if specified
    if (defined $self->{match}) {
        push @args, 'MATCH', $self->{match};
    }

    # Add COUNT hint if specified
    if (defined $self->{count}) {
        push @args, 'COUNT', $self->{count};
    }

    # Add TYPE filter for SCAN (Redis 6.0+)
    if ($self->{command} eq 'SCAN' && defined $self->{type}) {
        push @args, 'TYPE', $self->{type};
    }

    # Execute scan command
    my $result = await $self->{redis}->command($self->{command}, @args);

    # Result is [cursor, [elements...]]
    my ($new_cursor, $elements) = @$result;

    # Update cursor
    $self->{cursor} = $new_cursor;

    # Check if iteration complete (cursor returned to 0)
    if ($new_cursor eq '0' || $new_cursor == 0) {
        $self->{done} = 1;
    }

    # Return batch (may be empty)
    return $elements && @$elements ? $elements : ($self->{done} ? undef : []);
}

sub reset {
    my ($self) = @_;
    $self->{cursor} = 0;
    $self->{done} = 0;
}

sub cursor { shift->{cursor} }
sub done   { shift->{done} }

1;

__END__

=head1 NAME

Async::Redis::Iterator - Cursor-based SCAN iterator

=head1 SYNOPSIS

    my $iter = $redis->scan_iter(match => 'user:*', count => 100);

    while (my $batch = await $iter->next) {
        for my $key (@$batch) {
            say $key;
        }
    }

=head1 DESCRIPTION

Iterator provides async cursor-based iteration over Redis SCAN commands:

- SCAN: Iterate all keys
- HSCAN: Iterate hash fields
- SSCAN: Iterate set members
- ZSCAN: Iterate sorted set members with scores

=head2 Behavior

- Returns batches of elements, not individual items
- Cursor managed internally
- C<next> returns undef when iteration complete
- Safe during key modifications (may see duplicates or miss keys)
- C<count> is a hint, not a guarantee

=cut
```

### Step 4: Add scan_iter methods to Async::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
use Async::Redis::Iterator;

sub scan_iter {
    my ($self, %opts) = @_;
    return Async::Redis::Iterator->new(
        redis   => $self,
        command => 'SCAN',
        match   => $opts{match},
        count   => $opts{count},
        type    => $opts{type},
    );
}

sub hscan_iter {
    my ($self, $key, %opts) = @_;
    return Async::Redis::Iterator->new(
        redis   => $self,
        command => 'HSCAN',
        key     => $key,
        match   => $opts{match},
        count   => $opts{count},
    );
}

sub sscan_iter {
    my ($self, $key, %opts) = @_;
    return Async::Redis::Iterator->new(
        redis   => $self,
        command => 'SSCAN',
        key     => $key,
        match   => $opts{match},
        count   => $opts{count},
    );
}

sub zscan_iter {
    my ($self, $key, %opts) = @_;
    return Async::Redis::Iterator->new(
        redis   => $self,
        command => 'ZSCAN',
        key     => $key,
        match   => $opts{match},
        count   => $opts{count},
    );
}
```

### Step 5: Run basic SCAN test

Run: `prove -l t/80-scan/scan.t`
Expected: PASS

### Step 6: Write HSCAN test

```perl
# t/80-scan/hscan.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Setup test hash
    $loop->await($redis->del('hscan:hash'));
    for my $i (1..50) {
        $loop->await($redis->hset('hscan:hash', "field:$i", "value$i"));
    }

    subtest 'hscan_iter iterates all fields' => sub {
        my $iter = $redis->hscan_iter('hscan:hash');

        my @all_pairs;
        while (my $batch = $loop->await($iter->next)) {
            push @all_pairs, @$batch;
        }

        # HSCAN returns [field, value, field, value, ...]
        is(scalar @all_pairs, 100, '50 field-value pairs = 100 elements');

        my %hash = @all_pairs;
        is(scalar keys %hash, 50, '50 unique fields');
        is($hash{'field:1'}, 'value1', 'first field correct');
        is($hash{'field:50'}, 'value50', 'last field correct');
    };

    subtest 'hscan_iter with match pattern' => sub {
        my $iter = $redis->hscan_iter('hscan:hash', match => 'field:1*');

        my @all_pairs;
        while (my $batch = $loop->await($iter->next)) {
            push @all_pairs, @$batch;
        }

        my %hash = @all_pairs;
        # Should match field:1, field:10-19
        ok(scalar keys %hash >= 10, 'matched field:1* pattern');
        ok(exists $hash{'field:1'}, 'field:1 matched');
        ok(exists $hash{'field:10'}, 'field:10 matched');
    };

    subtest 'hscan_iter with count hint' => sub {
        my $iter = $redis->hscan_iter('hscan:hash', count => 10);

        my @batches;
        while (my $batch = $loop->await($iter->next)) {
            push @batches, $batch;
        }

        ok(@batches >= 1, 'got batches');

        my @all = map { @$_ } @batches;
        is(scalar @all, 100, 'found all field-value pairs');
    };

    # Cleanup
    $loop->await($redis->del('hscan:hash'));
}

done_testing;
```

### Step 7: Write SSCAN test

```perl
# t/80-scan/sscan.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Setup test set
    $loop->await($redis->del('sscan:set'));
    for my $i (1..100) {
        $loop->await($redis->sadd('sscan:set', "member:$i"));
    }

    subtest 'sscan_iter iterates all members' => sub {
        my $iter = $redis->sscan_iter('sscan:set');

        my @all_members;
        while (my $batch = $loop->await($iter->next)) {
            push @all_members, @$batch;
        }

        is(scalar @all_members, 100, 'found all 100 members');

        my %unique = map { $_ => 1 } @all_members;
        is(scalar keys %unique, 100, 'all members unique');
    };

    subtest 'sscan_iter with match pattern' => sub {
        my $iter = $redis->sscan_iter('sscan:set', match => 'member:5*');

        my @all_members;
        while (my $batch = $loop->await($iter->next)) {
            push @all_members, @$batch;
        }

        # Should match member:5, member:50-59
        ok(scalar @all_members >= 10, 'matched member:5* pattern');
        ok((grep { $_ eq 'member:5' } @all_members), 'member:5 matched');
    };

    # Cleanup
    $loop->await($redis->del('sscan:set'));
}

done_testing;
```

### Step 8: Write ZSCAN test

```perl
# t/80-scan/zscan.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Setup test sorted set
    $loop->await($redis->del('zscan:zset'));
    for my $i (1..50) {
        $loop->await($redis->zadd('zscan:zset', $i, "member:$i"));
    }

    subtest 'zscan_iter iterates all members with scores' => sub {
        my $iter = $redis->zscan_iter('zscan:zset');

        my @all_pairs;
        while (my $batch = $loop->await($iter->next)) {
            push @all_pairs, @$batch;
        }

        # ZSCAN returns [member, score, member, score, ...]
        is(scalar @all_pairs, 100, '50 member-score pairs = 100 elements');

        # Convert to hash for verification
        my %scores;
        for (my $i = 0; $i < @all_pairs; $i += 2) {
            $scores{$all_pairs[$i]} = $all_pairs[$i + 1];
        }

        is(scalar keys %scores, 50, '50 unique members');
        is($scores{'member:1'}, '1', 'member:1 has score 1');
        is($scores{'member:50'}, '50', 'member:50 has score 50');
    };

    subtest 'zscan_iter with match pattern' => sub {
        my $iter = $redis->zscan_iter('zscan:zset', match => 'member:1*');

        my @all_pairs;
        while (my $batch = $loop->await($iter->next)) {
            push @all_pairs, @$batch;
        }

        my %scores;
        for (my $i = 0; $i < @all_pairs; $i += 2) {
            $scores{$all_pairs[$i]} = $all_pairs[$i + 1];
        }

        # Should match member:1, member:10-19
        ok(scalar keys %scores >= 10, 'matched member:1* pattern');
    };

    # Cleanup
    $loop->await($redis->del('zscan:zset'));
}

done_testing;
```

### Step 9: Write MATCH pattern test

```perl
# t/80-scan/match.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Setup test keys with different patterns
    my @keys = (
        'match:user:1', 'match:user:2', 'match:user:10',
        'match:order:1', 'match:order:2',
        'match:product:a', 'match:product:b',
    );
    for my $key (@keys) {
        $loop->await($redis->set($key, 'value'));
    }

    subtest 'SCAN MATCH with wildcard' => sub {
        my $iter = $redis->scan_iter(match => 'match:user:*');

        my @found;
        while (my $batch = $loop->await($iter->next)) {
            push @found, @$batch;
        }

        is(scalar @found, 3, 'found 3 user keys');
        ok((grep { $_ eq 'match:user:1' } @found), 'found user:1');
        ok((grep { $_ eq 'match:user:2' } @found), 'found user:2');
        ok((grep { $_ eq 'match:user:10' } @found), 'found user:10');
    };

    subtest 'SCAN MATCH with character class' => sub {
        my $iter = $redis->scan_iter(match => 'match:*:1');

        my @found;
        while (my $batch = $loop->await($iter->next)) {
            push @found, @$batch;
        }

        is(scalar @found, 2, 'found 2 keys ending in :1');
        ok((grep { $_ eq 'match:user:1' } @found), 'found user:1');
        ok((grep { $_ eq 'match:order:1' } @found), 'found order:1');
    };

    subtest 'SCAN MATCH with question mark' => sub {
        my $iter = $redis->scan_iter(match => 'match:product:?');

        my @found;
        while (my $batch = $loop->await($iter->next)) {
            push @found, @$batch;
        }

        is(scalar @found, 2, 'found 2 product keys');
    };

    subtest 'SCAN MATCH with no matches' => sub {
        my $iter = $redis->scan_iter(match => 'match:nonexistent:*');

        my @found;
        while (my $batch = $loop->await($iter->next)) {
            push @found, @$batch;
        }

        is(scalar @found, 0, 'found no keys');
    };

    # Cleanup
    $loop->await($redis->del(@keys));
}

done_testing;
```

### Step 10: Write large dataset test

```perl
# t/80-scan/large.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    my $key_count = 1000;  # Adjust based on test environment

    # Setup large dataset
    subtest 'setup large dataset' => sub {
        my $pipe = $redis->pipeline;
        for my $i (1..$key_count) {
            $pipe->set("large:key:$i", "value$i");
        }
        $loop->await($pipe->execute);
        pass("created $key_count keys");
    };

    subtest 'scan_iter handles large dataset' => sub {
        my $iter = $redis->scan_iter(match => 'large:key:*', count => 100);

        my @all_keys;
        my $batch_count = 0;

        while (my $batch = $loop->await($iter->next)) {
            push @all_keys, @$batch;
            $batch_count++;
        }

        is(scalar @all_keys, $key_count, "found all $key_count keys");
        ok($batch_count >= 1, "iterated in $batch_count batches");

        my %unique = map { $_ => 1 } @all_keys;
        is(scalar keys %unique, $key_count, 'all keys unique');
    };

    subtest 'non-blocking during large scan' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $iter = $redis->scan_iter(match => 'large:key:*', count => 50);
        my $count = 0;

        while (my $batch = $loop->await($iter->next)) {
            $count += @$batch;
        }

        $timer->stop;
        $loop->remove($timer);

        is($count, $key_count, 'found all keys');
        ok(@ticks >= 5, "Event loop ticked " . scalar(@ticks) . " times during large scan");
    };

    subtest 'memory efficient iteration' => sub {
        # This test verifies we don't load all keys into memory at once
        # by checking that batches are reasonably sized

        my $iter = $redis->scan_iter(match => 'large:key:*', count => 100);

        my $max_batch_size = 0;
        my $batch_count = 0;

        while (my $batch = $loop->await($iter->next)) {
            my $size = scalar @$batch;
            $max_batch_size = $size if $size > $max_batch_size;
            $batch_count++;
        }

        ok($max_batch_size < $key_count, "max batch size $max_batch_size < total $key_count");
        ok($batch_count > 1, "used multiple batches ($batch_count)");
    };

    # Cleanup
    subtest 'cleanup large dataset' => sub {
        my $iter = $redis->scan_iter(match => 'large:key:*', count => 500);

        my @to_delete;
        while (my $batch = $loop->await($iter->next)) {
            push @to_delete, @$batch;
        }

        if (@to_delete) {
            $loop->await($redis->del(@to_delete));
        }

        pass("cleaned up $key_count keys");
    };
}

done_testing;
```

### Step 11: Run all SCAN tests

Run: `prove -l t/80-scan/`
Expected: PASS

### Step 12: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 13: Commit

```bash
git add lib/Future/IO/Redis/Iterator.pm lib/Future/IO/Redis.pm t/80-scan/
git commit -m "$(cat <<'EOF'
feat: implement SCAN iterators for memory-efficient iteration

Iterator.pm:
- Cursor-based async iteration
- Automatic cursor management
- next() returns batches, undef when done
- reset() for re-iteration
- Safe during key modifications

Main client methods:
- scan_iter(match, count, type): Iterate all keys
- hscan_iter(key, match, count): Iterate hash fields
- sscan_iter(key, match, count): Iterate set members
- zscan_iter(key, match, count): Iterate sorted set member-score pairs

Features:
- MATCH pattern filtering
- COUNT hint for batch size
- TYPE filter for SCAN (Redis 6.0+)
- Memory efficient (doesn't load all keys)

Test coverage:
- Basic SCAN iteration
- HSCAN with field-value pairs
- SSCAN with set members
- ZSCAN with member-score pairs
- MATCH pattern variants (*, ?, character classes)
- Large dataset (1000+ keys)
- Non-blocking verification

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

## Phase 4 Summary

| Task | Deliverable | Tests |
|------|-------------|-------|
| 12 | Blocking command timeout logic | 5 test files in `t/70-blocking/` |
| 13 | `lib/Future/IO/Redis/Iterator.pm` | 6 test files in `t/80-scan/` |

**Blocking Commands:**
- BLPOP/BRPOP: Block until list has items
- BLMOVE: Atomically move with blocking
- BZPOPMIN/BZPOPMAX: Blocking sorted set pop
- BRPOPLPUSH: Deprecated but supported
- Client deadline = server_timeout + blocking_timeout_buffer
- Zero timeout = indefinite wait
- Non-blocking: event loop ticks during wait

**SCAN Iterators:**
- `scan_iter()`: Iterate all keys with MATCH/COUNT/TYPE
- `hscan_iter()`: Hash fields
- `sscan_iter()`: Set members
- `zscan_iter()`: Sorted set member-score pairs
- Memory efficient: batched iteration
- `next()` returns batches, `undef` when done

**Total new files:** 12
**Estimated tests:** 100+ assertions

---

## Next Phase

After Phase 4 is complete, Phase 5 will cover:
- **Task 14:** Pipeline Refinement (error handling, depth limits)
- **Task 15:** Auto-Pipelining (automatic command batching)
