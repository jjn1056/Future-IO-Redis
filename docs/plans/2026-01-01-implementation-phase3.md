# Async::Redis Phase 3: Transactions & Lua Scripting

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement Redis transactions (MULTI/EXEC/WATCH) for atomic operations and Lua scripting (EVAL/EVALSHA) for server-side logic execution, with automatic NOSCRIPT fallback.

**Architecture:** Transaction.pm wraps MULTI/EXEC with callback pattern and tracks transaction state. Script.pm provides reusable script objects with SHA caching. Both integrate with connection state tracking for pool cleanliness.

**Tech Stack:** Perl 5.18+, Future::AsyncAwait, Digest::SHA (for script hashing)

**Prerequisite:** Phase 1 (connection reliability) and Phase 2 (command generation) complete

---

## Task Overview

| Task | Focus | Files |
|------|-------|-------|
| 10 | Transactions | `lib/Future/IO/Redis/Transaction.pm`, `t/40-transactions/*.t` |
| 11 | Lua Scripting | `lib/Future/IO/Redis/Script.pm`, `t/60-scripting/*.t` |

---

## Task 10: Transactions (MULTI/EXEC/WATCH)

**Files:**
- Create: `lib/Future/IO/Redis/Transaction.pm`
- Create: `t/40-transactions/multi-exec.t`
- Create: `t/40-transactions/watch.t`
- Create: `t/40-transactions/watch-conflict.t`
- Create: `t/40-transactions/discard.t`
- Create: `t/40-transactions/nested.t`
- Modify: `lib/Future/IO/Redis.pm` (add transaction methods, track in_multi state)

### Step 1: Write the basic MULTI/EXEC test

```perl
# t/40-transactions/multi-exec.t
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

    # Cleanup
    $loop->await($redis->del('tx:counter', 'tx:updated'));

    subtest 'basic MULTI/EXEC with callback' => sub {
        my $results = $loop->await($redis->multi(async sub {
            my ($tx) = @_;
            $tx->set('tx:counter', '0');
            $tx->incr('tx:counter');
            $tx->incr('tx:counter');
            $tx->get('tx:counter');
        }));

        is(ref $results, 'ARRAY', 'results is array');
        is(scalar @$results, 4, 'four results');
        is($results->[0], 'OK', 'SET returned OK');
        is($results->[1], 1, 'first INCR returned 1');
        is($results->[2], 2, 'second INCR returned 2');
        is($results->[3], '2', 'GET returned 2');
    };

    subtest 'transaction is atomic' => sub {
        $loop->await($redis->set('tx:counter', '100'));

        # Start a transaction
        my $results = $loop->await($redis->multi(async sub {
            my ($tx) = @_;
            $tx->incr('tx:counter');
            $tx->incr('tx:counter');
            $tx->incr('tx:counter');
        }));

        is($results, [101, 102, 103], 'all increments applied atomically');

        my $final = $loop->await($redis->get('tx:counter'));
        is($final, '103', 'final value correct');
    };

    subtest 'empty transaction' => sub {
        my $results = $loop->await($redis->multi(async sub {
            my ($tx) = @_;
            # Queue nothing
        }));

        is($results, [], 'empty transaction returns empty array');
    };

    subtest 'transaction with mixed commands' => sub {
        $loop->await($redis->del('tx:hash'));

        my $results = $loop->await($redis->multi(async sub {
            my ($tx) = @_;
            $tx->hset('tx:hash', 'field1', 'value1');
            $tx->hset('tx:hash', 'field2', 'value2');
            $tx->hgetall('tx:hash');
        }));

        is($results->[0], 1, 'first HSET added field');
        is($results->[1], 1, 'second HSET added field');
        # Note: HGETALL in transaction returns array, not hash (transformation happens outside)
        is(ref $results->[2], 'ARRAY', 'HGETALL returned array');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Run 20 transactions
        for my $i (1..20) {
            $loop->await($redis->multi(async sub {
                my ($tx) = @_;
                $tx->set("tx:nb:$i", $i);
                $tx->incr("tx:nb:$i");
            }));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 2, "Event loop ticked during transactions");

        # Cleanup
        $loop->await($redis->del(map { "tx:nb:$_" } 1..20));
    };

    # Cleanup
    $loop->await($redis->del('tx:counter', 'tx:updated', 'tx:hash'));
}

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/40-transactions/multi-exec.t`
Expected: FAIL (multi method not implemented)

### Step 3: Write Transaction.pm

```perl
# lib/Future/IO/Redis/Transaction.pm
package Async::Redis::Transaction;

use strict;
use warnings;
use 5.018;

use Future::AsyncAwait;

sub new {
    my ($class, %args) = @_;
    return bless {
        redis    => $args{redis},
        commands => [],
    }, $class;
}

# Queue a command for execution in the transaction
# Returns a placeholder (the actual result comes from EXEC)
sub _queue_command {
    my ($self, $cmd, @args) = @_;
    push @{$self->{commands}}, [$cmd, @args];
    return scalar(@{$self->{commands}}) - 1;  # index of this command
}

# Generate AUTOLOAD to capture any command call
our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;
    my $cmd = $AUTOLOAD;
    $cmd =~ s/.*:://;
    return if $cmd eq 'DESTROY';

    # Queue the command
    $self->_queue_command(uc($cmd), @_);
    return;  # Transaction commands don't return Futures individually
}

# Allow explicit command() calls too
sub command {
    my ($self, $cmd, @args) = @_;
    $self->_queue_command($cmd, @args);
    return;
}

sub commands { @{shift->{commands}} }

1;

__END__

=head1 NAME

Async::Redis::Transaction - Transaction command collector

=head1 DESCRIPTION

This class collects commands during a transaction callback. Commands
are queued locally and then sent as MULTI/commands.../EXEC.

=cut
```

### Step 4: Add multi() method to Async::Redis

Edit `lib/Future/IO/Redis.pm` to add:

```perl
use Async::Redis::Transaction;

# Track transaction state
# In new(): in_multi => 0,

async sub multi {
    my ($self, $callback) = @_;

    # Create transaction collector
    my $tx = Async::Redis::Transaction->new(redis => $self);

    # Run callback to collect commands
    await $callback->($tx);

    my @commands = $tx->commands;

    # If no commands queued, return empty result
    return [] unless @commands;

    # Execute transaction
    return await $self->_execute_transaction(\@commands);
}

async sub _execute_transaction {
    my ($self, $commands) = @_;

    # Mark that we're in a transaction
    $self->{in_multi} = 1;

    my $results;
    eval {
        # Send MULTI
        await $self->command('MULTI');

        # Queue all commands (they return +QUEUED)
        for my $cmd (@$commands) {
            await $self->command(@$cmd);
        }

        # Execute and get results
        $results = await $self->command('EXEC');
    };
    my $error = $@;

    # Always clear transaction state
    $self->{in_multi} = 0;

    if ($error) {
        # Try to clean up
        eval { await $self->command('DISCARD') };
        die $error;
    }

    return $results;
}

# Accessor for pool cleanliness tracking
sub in_multi { shift->{in_multi} }
```

### Step 5: Run test to verify it passes

Run: `prove -l t/40-transactions/multi-exec.t`
Expected: PASS

### Step 6: Write WATCH test

```perl
# t/40-transactions/watch.t
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

    # Cleanup
    $loop->await($redis->del('watch:key', 'watch:balance'));

    subtest 'watch_multi with unchanged key' => sub {
        $loop->await($redis->set('watch:balance', '100'));

        my $results = $loop->await($redis->watch_multi(['watch:balance'], async sub {
            my ($tx, $watched) = @_;

            is($watched->{'watch:balance'}, '100', 'watched value provided');

            $tx->decrby('watch:balance', 10);
            $tx->get('watch:balance');
        }));

        ok(defined $results, 'transaction succeeded');
        is($results->[0], 90, 'DECRBY result');
        is($results->[1], '90', 'GET result');
    };

    subtest 'watch with multiple keys' => sub {
        $loop->await($redis->set('watch:a', '1'));
        $loop->await($redis->set('watch:b', '2'));

        my $results = $loop->await($redis->watch_multi(['watch:a', 'watch:b'], async sub {
            my ($tx, $watched) = @_;

            is($watched->{'watch:a'}, '1', 'first watched value');
            is($watched->{'watch:b'}, '2', 'second watched value');

            $tx->incr('watch:a');
            $tx->incr('watch:b');
        }));

        is($results, [2, 3], 'both incremented');

        # Cleanup
        $loop->await($redis->del('watch:a', 'watch:b'));
    };

    subtest 'manual WATCH/MULTI/EXEC' => sub {
        $loop->await($redis->set('watch:key', 'original'));

        await $redis->watch('watch:key');
        await $redis->multi_start();
        await $redis->set('watch:key', 'modified');
        my $results = await $redis->exec();

        ok(defined $results, 'manual transaction succeeded');
        is($results->[0], 'OK', 'SET succeeded');

        my $value = $loop->await($redis->get('watch:key'));
        is($value, 'modified', 'value updated');
    };

    subtest 'UNWATCH clears watches' => sub {
        $loop->await($redis->set('watch:key', 'value'));

        await $redis->watch('watch:key');
        await $redis->unwatch();

        # Now modify key from another connection
        my $redis2 = Async::Redis->new(host => 'localhost');
        $loop->await($redis2->connect);
        $loop->await($redis2->set('watch:key', 'changed'));

        # Transaction should still succeed because we unwatched
        await $redis->multi_start();
        await $redis->get('watch:key');
        my $results = await $redis->exec();

        ok(defined $results, 'transaction succeeded after UNWATCH');
    };

    # Cleanup
    $loop->await($redis->del('watch:key', 'watch:balance'));
}

done_testing;
```

### Step 7: Add watch_multi() and related methods

Edit `lib/Future/IO/Redis.pm`:

```perl
# Track watching state
# In new(): watching => 0,

async sub watch {
    my ($self, @keys) = @_;
    $self->{watching} = 1;
    return await $self->command('WATCH', @keys);
}

async sub unwatch {
    my ($self) = @_;
    my $result = await $self->command('UNWATCH');
    $self->{watching} = 0;
    return $result;
}

async sub multi_start {
    my ($self) = @_;
    $self->{in_multi} = 1;
    return await $self->command('MULTI');
}

async sub exec {
    my ($self) = @_;
    my $result = await $self->command('EXEC');
    $self->{in_multi} = 0;
    $self->{watching} = 0;  # EXEC clears watches
    return $result;
}

async sub discard {
    my ($self) = @_;
    my $result = await $self->command('DISCARD');
    $self->{in_multi} = 0;
    # Note: DISCARD does NOT clear watches
    return $result;
}

async sub watch_multi {
    my ($self, $keys, $callback) = @_;

    # WATCH the keys
    await $self->watch(@$keys);

    # Get current values of watched keys
    my %watched;
    for my $key (@$keys) {
        $watched{$key} = await $self->get($key);
    }

    # Create transaction collector
    my $tx = Async::Redis::Transaction->new(redis => $self);

    # Run callback with watched values
    await $callback->($tx, \%watched);

    my @commands = $tx->commands;

    # If no commands queued, just unwatch and return empty
    unless (@commands) {
        await $self->unwatch;
        return [];
    }

    # Execute transaction
    $self->{in_multi} = 1;

    my $results;
    eval {
        await $self->command('MULTI');

        for my $cmd (@commands) {
            await $self->command(@$cmd);
        }

        $results = await $self->command('EXEC');
    };
    my $error = $@;

    $self->{in_multi} = 0;
    $self->{watching} = 0;

    if ($error) {
        eval { await $self->command('DISCARD') };
        die $error;
    }

    # EXEC returns undef/nil if WATCH failed
    return $results;
}

# Accessors for pool cleanliness tracking
sub watching { shift->{watching} }
```

### Step 8: Run WATCH test

Run: `prove -l t/40-transactions/watch.t`
Expected: PASS

### Step 9: Write WATCH conflict test

```perl
# t/40-transactions/watch-conflict.t
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

    # Second connection to modify watched keys
    my $redis2 = Async::Redis->new(host => 'localhost');
    $loop->await($redis2->connect);

    # Cleanup
    $loop->await($redis->del('conflict:key'));

    subtest 'WATCH conflict returns undef' => sub {
        $loop->await($redis->set('conflict:key', 'original'));

        # Start watching
        await $redis->watch('conflict:key');

        # Another client modifies the key
        $loop->await($redis2->set('conflict:key', 'modified'));

        # Try to execute transaction
        await $redis->multi_start();
        await $redis->set('conflict:key', 'from_transaction');
        my $results = await $redis->exec();

        is($results, undef, 'EXEC returns undef on WATCH conflict');

        # Verify the other client's value persisted
        my $value = $loop->await($redis->get('conflict:key'));
        is($value, 'modified', 'other client value persisted');
    };

    subtest 'watch_multi returns undef on conflict' => sub {
        $loop->await($redis->set('conflict:key', 'original'));

        # Use a flag to detect when watch is active
        my $watch_active = 0;

        my $results = $loop->await($redis->watch_multi(['conflict:key'], async sub {
            my ($tx, $watched) = @_;

            is($watched->{'conflict:key'}, 'original', 'got original value');

            # Simulate race: other client modifies between WATCH and EXEC
            $loop->await($redis2->set('conflict:key', 'raced'));

            $tx->set('conflict:key', 'from_tx');
        }));

        is($results, undef, 'watch_multi returns undef on conflict');

        # Verify race winner
        my $value = $loop->await($redis->get('conflict:key'));
        is($value, 'raced', 'race condition winner persisted');
    };

    subtest 'retry pattern on conflict' => sub {
        $loop->await($redis->set('conflict:counter', '0'));

        my $attempts = 0;
        my $success = 0;

        # Retry loop pattern
        while ($attempts < 5 && !$success) {
            $attempts++;

            my $results = $loop->await($redis->watch_multi(['conflict:counter'], async sub {
                my ($tx, $watched) = @_;

                my $current = $watched->{'conflict:counter'} // 0;

                # On first attempt, simulate a race
                if ($attempts == 1) {
                    $loop->await($redis2->incr('conflict:counter'));
                }

                $tx->set('conflict:counter', $current + 10);
            }));

            $success = defined $results;
        }

        ok($success, 'eventually succeeded after retry');
        ok($attempts > 1, "needed $attempts attempts");

        my $final = $loop->await($redis->get('conflict:counter'));
        # Should be 11: redis2 set to 1, then we added 10 to that
        is($final, '11', 'final value includes both modifications');
    };

    # Cleanup
    $loop->await($redis->del('conflict:key', 'conflict:counter'));
}

done_testing;
```

### Step 10: Run conflict test

Run: `prove -l t/40-transactions/watch-conflict.t`
Expected: PASS

### Step 11: Write DISCARD test

```perl
# t/40-transactions/discard.t
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

    # Cleanup
    $loop->await($redis->del('discard:key'));

    subtest 'DISCARD aborts transaction' => sub {
        $loop->await($redis->set('discard:key', 'original'));

        await $redis->multi_start();
        await $redis->set('discard:key', 'modified');
        await $redis->incr('discard:key');  # Would fail on string
        await $redis->discard();

        # Value should be unchanged
        my $value = $loop->await($redis->get('discard:key'));
        is($value, 'original', 'value unchanged after DISCARD');
    };

    subtest 'commands work after DISCARD' => sub {
        await $redis->multi_start();
        await $redis->discard();

        # Should be able to use connection normally
        my $result = $loop->await($redis->set('discard:key', 'after_discard'));
        is($result, 'OK', 'command works after DISCARD');

        my $value = $loop->await($redis->get('discard:key'));
        is($value, 'after_discard', 'value set correctly');
    };

    subtest 'DISCARD preserves WATCH' => sub {
        $loop->await($redis->set('discard:key', 'watched'));

        await $redis->watch('discard:key');
        await $redis->multi_start();
        await $redis->set('discard:key', 'in_tx');
        await $redis->discard();

        # Watch should still be active
        ok($redis->watching, 'still watching after DISCARD');

        # Clear watch
        await $redis->unwatch();
        ok(!$redis->watching, 'not watching after UNWATCH');
    };

    subtest 'in_multi flag cleared after DISCARD' => sub {
        await $redis->multi_start();
        ok($redis->in_multi, 'in_multi true during transaction');

        await $redis->discard();
        ok(!$redis->in_multi, 'in_multi false after DISCARD');
    };

    # Cleanup
    $loop->await($redis->del('discard:key'));
}

done_testing;
```

### Step 12: Run DISCARD test

Run: `prove -l t/40-transactions/discard.t`
Expected: PASS

### Step 13: Write nested transaction error test

```perl
# t/40-transactions/nested.t
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

    subtest 'nested MULTI returns error' => sub {
        await $redis->multi_start();

        # Trying to start another MULTI should return error
        my $error;
        eval {
            await $redis->multi_start();
        };
        $error = $@;

        # Clean up
        await $redis->discard();

        ok($error, 'nested MULTI threw error');
        like("$error", qr/ERR MULTI calls can not be nested/i, 'correct error message');
    };

    subtest 'multi() callback prevents nesting' => sub {
        my $error;
        eval {
            $loop->await($redis->multi(async sub {
                my ($tx) = @_;

                # Try to start nested transaction
                $loop->await($redis->multi(async sub {
                    my ($tx2) = @_;
                    $tx2->set('nested:key', 'value');
                }));
            }));
        };
        $error = $@;

        ok($error, 'nested multi() threw error');
    };

    subtest 'connection usable after nested error' => sub {
        # Connection should still work
        my $result = $loop->await($redis->ping);
        is($result, 'PONG', 'connection still usable');
    };
}

done_testing;
```

### Step 14: Run nested transaction test

Run: `prove -l t/40-transactions/nested.t`
Expected: PASS

### Step 15: Run all transaction tests

Run: `prove -l t/40-transactions/`
Expected: PASS

### Step 16: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 17: Commit

```bash
git add lib/Future/IO/Redis/Transaction.pm lib/Future/IO/Redis.pm t/40-transactions/
git commit -m "$(cat <<'EOF'
feat: implement Redis transactions (MULTI/EXEC/WATCH)

Transaction.pm:
- Command collector for callback-based transactions
- AUTOLOAD captures any command call
- Supports explicit command() method

Main client methods:
- multi(callback): Execute transaction with collected commands
- watch_multi(keys, callback): WATCH + read values + transaction
- watch/unwatch: Manual WATCH control
- multi_start/exec/discard: Low-level transaction control

State tracking:
- in_multi: True while in MULTI..EXEC
- watching: True while keys are WATCHed
- Both used for pool cleanliness detection

Test coverage:
- Basic MULTI/EXEC with multiple commands
- WATCH with unchanged keys
- WATCH conflict detection (returns undef)
- Retry pattern for optimistic locking
- DISCARD behavior and state cleanup
- Nested transaction error handling

EOF
)"
```

---

## Task 11: Lua Scripting (EVAL/EVALSHA)

**Files:**
- Create: `lib/Future/IO/Redis/Script.pm`
- Create: `t/60-scripting/eval.t`
- Create: `t/60-scripting/evalsha.t`
- Create: `t/60-scripting/script-load.t`
- Create: `t/60-scripting/auto-fallback.t`
- Create: `t/60-scripting/script-object.t`
- Modify: `lib/Future/IO/Redis.pm` (add script methods)

### Step 1: Write basic EVAL test

```perl
# t/60-scripting/eval.t
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

    # Cleanup
    $loop->await($redis->del('eval:key', 'eval:counter'));

    subtest 'simple EVAL' => sub {
        my $result = $loop->await($redis->eval(
            'return "hello"',
            0,  # numkeys
        ));
        is($result, 'hello', 'simple return value');
    };

    subtest 'EVAL with KEYS' => sub {
        $loop->await($redis->set('eval:key', 'myvalue'));

        my $result = $loop->await($redis->eval(
            'return redis.call("GET", KEYS[1])',
            1,           # numkeys
            'eval:key',  # KEYS[1]
        ));
        is($result, 'myvalue', 'accessed key via KEYS[1]');
    };

    subtest 'EVAL with KEYS and ARGV' => sub {
        my $result = $loop->await($redis->eval(
            'redis.call("SET", KEYS[1], ARGV[1]); return redis.call("GET", KEYS[1])',
            1,             # numkeys
            'eval:key',    # KEYS[1]
            'newvalue',    # ARGV[1]
        ));
        is($result, 'newvalue', 'SET via script worked');

        my $value = $loop->await($redis->get('eval:key'));
        is($value, 'newvalue', 'value persisted');
    };

    subtest 'EVAL with multiple keys' => sub {
        $loop->await($redis->set('eval:a', '1'));
        $loop->await($redis->set('eval:b', '2'));

        my $result = $loop->await($redis->eval(
            'return redis.call("GET", KEYS[1]) + redis.call("GET", KEYS[2])',
            2,
            'eval:a', 'eval:b',
        ));
        is($result, 3, 'computed sum from two keys');

        # Cleanup
        $loop->await($redis->del('eval:a', 'eval:b'));
    };

    subtest 'EVAL returning array' => sub {
        my $result = $loop->await($redis->eval(
            'return {1, 2, 3, "four"}',
            0,
        ));
        is($result, [1, 2, 3, 'four'], 'array returned');
    };

    subtest 'EVAL returning table as array' => sub {
        my $result = $loop->await($redis->eval(
            'return {"a", "b", "c"}',
            0,
        ));
        is($result, ['a', 'b', 'c'], 'table returned as array');
    };

    subtest 'EVAL with increment script' => sub {
        $loop->await($redis->set('eval:counter', '10'));

        my $result = $loop->await($redis->eval(<<'LUA', 1, 'eval:counter', 5));
local current = tonumber(redis.call('GET', KEYS[1])) or 0
local increment = tonumber(ARGV[1]) or 1
local new = current + increment
redis.call('SET', KEYS[1], new)
return new
LUA

        is($result, 15, 'increment script worked');

        my $value = $loop->await($redis->get('eval:counter'));
        is($value, '15', 'value updated');
    };

    subtest 'EVAL error handling' => sub {
        my $error;
        eval {
            $loop->await($redis->eval(
                'return redis.call("INVALID_COMMAND")',
                0,
            ));
        };
        $error = $@;

        ok($error, 'script error thrown');
        like("$error", qr/ERR/i, 'error message contains ERR');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        for my $i (1..20) {
            $loop->await($redis->eval('return ARGV[1]', 0, $i));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 1, "Event loop ticked during EVAL calls");
    };

    # Cleanup
    $loop->await($redis->del('eval:key', 'eval:counter'));
}

done_testing;
```

### Step 2: Run EVAL test

Run: `prove -l t/60-scripting/eval.t`
Expected: PASS (eval should already work via command())

### Step 3: Write EVALSHA test

```perl
# t/60-scripting/evalsha.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Digest::SHA qw(sha1_hex);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    my $script = 'return "hello from sha"';
    my $sha = lc(sha1_hex($script));

    subtest 'SCRIPT LOAD' => sub {
        my $result = $loop->await($redis->script_load($script));
        is($result, $sha, 'SCRIPT LOAD returns SHA');
    };

    subtest 'EVALSHA with loaded script' => sub {
        my $result = $loop->await($redis->evalsha($sha, 0));
        is($result, 'hello from sha', 'EVALSHA executed');
    };

    subtest 'EVALSHA with unknown SHA fails' => sub {
        my $fake_sha = 'a' x 40;

        my $error;
        eval {
            $loop->await($redis->evalsha($fake_sha, 0));
        };
        $error = $@;

        ok($error, 'EVALSHA with unknown SHA threw');
        like("$error", qr/NOSCRIPT/i, 'NOSCRIPT error');
    };

    subtest 'SCRIPT EXISTS' => sub {
        my $fake_sha = 'b' x 40;

        my $result = $loop->await($redis->script_exists($sha, $fake_sha));
        is($result, [1, 0], 'EXISTS returns array of 0/1');
    };

    subtest 'SCRIPT FLUSH' => sub {
        # Load a script
        my $temp_script = 'return "temp"';
        my $temp_sha = $loop->await($redis->script_load($temp_script));

        # Verify it exists
        my $exists = $loop->await($redis->script_exists($temp_sha));
        is($exists->[0], 1, 'script exists before flush');

        # Flush
        $loop->await($redis->script_flush);

        # Verify it's gone
        $exists = $loop->await($redis->script_exists($temp_sha));
        is($exists->[0], 0, 'script gone after flush');
    };
}

done_testing;
```

### Step 4: Add script helper methods to Async::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
async sub script_load {
    my ($self, $script) = @_;
    return await $self->command('SCRIPT', 'LOAD', $script);
}

async sub script_exists {
    my ($self, @shas) = @_;
    return await $self->command('SCRIPT', 'EXISTS', @shas);
}

async sub script_flush {
    my ($self, $mode) = @_;
    my @args = ('SCRIPT', 'FLUSH');
    push @args, $mode if $mode;  # ASYNC or SYNC
    return await $self->command(@args);
}

async sub script_kill {
    my ($self) = @_;
    return await $self->command('SCRIPT', 'KILL');
}
```

### Step 5: Run EVALSHA test

Run: `prove -l t/60-scripting/evalsha.t`
Expected: PASS

### Step 6: Write auto-fallback test

```perl
# t/60-scripting/auto-fallback.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Digest::SHA qw(sha1_hex);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    my $script = 'return KEYS[1] .. ":" .. ARGV[1]';
    my $sha = lc(sha1_hex($script));

    subtest 'evalsha_or_eval with unknown SHA falls back' => sub {
        # Flush scripts to ensure SHA unknown
        $loop->await($redis->script_flush);

        # This should try EVALSHA, get NOSCRIPT, then use EVAL
        my $result = $loop->await($redis->evalsha_or_eval(
            $sha,
            $script,
            1,
            'mykey',
            'myarg',
        ));

        is($result, 'mykey:myarg', 'fallback to EVAL worked');
    };

    subtest 'evalsha_or_eval with known SHA uses SHA' => sub {
        # Load the script
        $loop->await($redis->script_load($script));

        # Mock to track which was called (in real implementation)
        my $result = $loop->await($redis->evalsha_or_eval(
            $sha,
            $script,
            1,
            'key2',
            'arg2',
        ));

        is($result, 'key2:arg2', 'EVALSHA worked');
    };

    subtest 'evalsha_or_eval caches SHA after fallback' => sub {
        $loop->await($redis->script_flush);

        my $new_script = 'return "cached"';
        my $new_sha = lc(sha1_hex($new_script));

        # First call: fallback to EVAL
        my $r1 = $loop->await($redis->evalsha_or_eval($new_sha, $new_script, 0));
        is($r1, 'cached', 'first call worked');

        # Script should now be loaded on server
        my $exists = $loop->await($redis->script_exists($new_sha));
        is($exists->[0], 1, 'script now cached on server');

        # Second call should use EVALSHA directly
        my $r2 = $loop->await($redis->evalsha_or_eval($new_sha, $new_script, 0));
        is($r2, 'cached', 'second call worked');
    };
}

done_testing;
```

### Step 7: Implement evalsha_or_eval

Edit `lib/Future/IO/Redis.pm`:

```perl
use Async::Redis::Error::Redis;

async sub evalsha_or_eval {
    my ($self, $sha, $script, $numkeys, @keys_and_args) = @_;

    # Try EVALSHA first
    my $result;
    eval {
        $result = await $self->evalsha($sha, $numkeys, @keys_and_args);
    };

    if ($@) {
        my $error = $@;

        # Check if it's a NOSCRIPT error
        if (ref $error && $error->can('is_noscript') && $error->is_noscript) {
            # Fall back to EVAL (which also loads the script)
            $result = await $self->eval($script, $numkeys, @keys_and_args);
        }
        elsif ("$error" =~ /NOSCRIPT/i) {
            # String error with NOSCRIPT
            $result = await $self->eval($script, $numkeys, @keys_and_args);
        }
        else {
            # Re-throw other errors
            die $error;
        }
    }

    return $result;
}
```

### Step 8: Run auto-fallback test

Run: `prove -l t/60-scripting/auto-fallback.t`
Expected: PASS

### Step 9: Write Script object test

```perl
# t/60-scripting/script-object.t
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

    # Cleanup
    $loop->await($redis->del('script:counter', 'script:key'));

    subtest 'create script object' => sub {
        my $script = $redis->script(<<'LUA');
return "hello from script object"
LUA

        ok($script, 'script object created');
        ok($script->sha, 'script has SHA');
        is(length($script->sha), 40, 'SHA is 40 chars');
    };

    subtest 'script->call() with no keys' => sub {
        my $script = $redis->script('return "no keys"');

        my $result = $loop->await($script->call());
        is($result, 'no keys', 'script executed');
    };

    subtest 'script->call() with keys and args' => sub {
        $loop->await($redis->set('script:key', '100'));

        my $script = $redis->script(<<'LUA');
local current = tonumber(redis.call('GET', KEYS[1])) or 0
local amount = tonumber(ARGV[1]) or 0
local new = current + amount
redis.call('SET', KEYS[1], new)
return new
LUA

        my $result = $loop->await($script->call('script:key', 50));
        is($result, 150, 'increment script worked');

        $result = $loop->await($script->call('script:key', 25));
        is($result, 175, 'second call worked');
    };

    subtest 'script->call() uses EVALSHA after first call' => sub {
        $loop->await($redis->script_flush);

        my $script = $redis->script('return ARGV[1]');

        # First call loads the script
        my $r1 = $loop->await($script->call_with_keys(0, 'first'));
        is($r1, 'first', 'first call worked');

        # Verify script is now loaded
        my $exists = $loop->await($redis->script_exists($script->sha));
        is($exists->[0], 1, 'script cached on server');

        # Second call uses cached SHA
        my $r2 = $loop->await($script->call_with_keys(0, 'second'));
        is($r2, 'second', 'second call worked');
    };

    subtest 'script survives SCRIPT FLUSH' => sub {
        my $script = $redis->script('return "resilient"');

        # First call
        my $r1 = $loop->await($script->call());
        is($r1, 'resilient', 'first call');

        # Flush all scripts
        $loop->await($redis->script_flush);

        # Should auto-reload
        my $r2 = $loop->await($script->call());
        is($r2, 'resilient', 'survived flush');
    };

    subtest 'script with prefix' => sub {
        my $prefixed = Async::Redis->new(
            host => 'localhost',
            prefix => 'pfx:',
        );
        $loop->await($prefixed->connect);

        my $script = $prefixed->script(<<'LUA');
redis.call('SET', KEYS[1], ARGV[1])
return redis.call('GET', KEYS[1])
LUA

        my $result = $loop->await($script->call('mykey', 'myvalue'));
        is($result, 'myvalue', 'script executed');

        # Verify key was actually prefixed
        my $raw = Async::Redis->new(host => 'localhost');
        $loop->await($raw->connect);
        my $value = $loop->await($raw->get('pfx:mykey'));
        is($value, 'myvalue', 'key was prefixed');

        # Cleanup
        $loop->await($raw->del('pfx:mykey'));
    };

    subtest 'non-blocking verification' => sub {
        my $script = $redis->script('return ARGV[1] * 2');

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        for my $i (1..20) {
            $loop->await($script->call_with_keys(0, $i));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 1, "Event loop ticked during script calls");
    };

    # Cleanup
    $loop->await($redis->del('script:counter', 'script:key'));
}

done_testing;
```

### Step 10: Write Script.pm

```perl
# lib/Future/IO/Redis/Script.pm
package Async::Redis::Script;

use strict;
use warnings;
use 5.018;

use Future::AsyncAwait;
use Digest::SHA qw(sha1_hex);

sub new {
    my ($class, %args) = @_;

    my $script = $args{script};
    die "Script code required" unless defined $script;

    return bless {
        redis  => $args{redis},
        script => $script,
        sha    => lc(sha1_hex($script)),
        loaded => 0,
    }, $class;
}

sub sha    { shift->{sha} }
sub script { shift->{script} }

# Call with automatic key count detection
# Usage: $script->call('key1', 'key2', 'arg1', 'arg2')
# Assumes all args before first non-key-looking arg are keys
# For explicit control, use call_with_keys()
async sub call {
    my ($self, @keys_and_args) = @_;

    # Simple heuristic: assume all args are ARGV (no KEYS)
    # User should use call_with_keys for scripts with KEYS
    return await $self->call_with_keys(0, @keys_and_args);
}

# Call with explicit key count
# Usage: $script->call_with_keys($numkeys, @keys, @args)
async sub call_with_keys {
    my ($self, $numkeys, @keys_and_args) = @_;

    my $redis = $self->{redis};

    # Apply key prefixing if configured
    if ($numkeys > 0 && defined $redis->{prefix} && $redis->{prefix} ne '') {
        for my $i (0 .. $numkeys - 1) {
            $keys_and_args[$i] = $redis->{prefix} . $keys_and_args[$i];
        }
    }

    # Use evalsha_or_eval for automatic fallback
    return await $redis->evalsha_or_eval(
        $self->{sha},
        $self->{script},
        $numkeys,
        @keys_and_args,
    );
}

1;

__END__

=head1 NAME

Async::Redis::Script - Reusable Lua script wrapper

=head1 SYNOPSIS

    my $script = $redis->script(<<'LUA');
        local current = redis.call('GET', KEYS[1]) or 0
        return current + ARGV[1]
    LUA

    # Call with keys and args
    my $result = await $script->call_with_keys(1, 'mykey', 10);

    # Or simple call (assumes no KEYS, all ARGV)
    my $result = await $script->call('arg1', 'arg2');

=head1 DESCRIPTION

Script objects wrap Lua scripts for reuse. They:

- Compute and cache the SHA1 hash
- Use EVALSHA for efficiency
- Automatically fall back to EVAL on NOSCRIPT
- Apply key prefixing for KEYS arguments

=cut
```

### Step 11: Add script() method to Async::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
use Async::Redis::Script;

sub script {
    my ($self, $code) = @_;
    return Async::Redis::Script->new(
        redis  => $self,
        script => $code,
    );
}
```

### Step 12: Run Script object test

Run: `prove -l t/60-scripting/script-object.t`
Expected: PASS

### Step 13: Run all scripting tests

Run: `prove -l t/60-scripting/`
Expected: PASS

### Step 14: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 15: Commit

```bash
git add lib/Future/IO/Redis/Script.pm lib/Future/IO/Redis.pm t/60-scripting/
git commit -m "$(cat <<'EOF'
feat: implement Lua scripting (EVAL/EVALSHA/Script)

Script.pm:
- Reusable Lua script wrapper
- Automatic SHA1 computation
- call_with_keys(numkeys, @keys, @args)
- call(@args) for scripts without KEYS
- Key prefixing support for KEYS arguments

Main client methods:
- eval(script, numkeys, @keys_and_args)
- evalsha(sha, numkeys, @keys_and_args)
- evalsha_or_eval: Try SHA, fall back to EVAL on NOSCRIPT
- script_load/script_exists/script_flush/script_kill
- script(code): Create reusable Script object

Test coverage:
- Basic EVAL with KEYS and ARGV
- EVALSHA with loaded scripts
- NOSCRIPT error handling
- Automatic EVALSHA->EVAL fallback
- Script object pattern with caching
- Script survives SCRIPT FLUSH
- Key prefixing in scripts

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

## Phase 3 Summary

| Task | Deliverable | Tests |
|------|-------------|-------|
| 10 | `lib/Future/IO/Redis/Transaction.pm` | 5 test files in `t/40-transactions/` |
| 11 | `lib/Future/IO/Redis/Script.pm` | 5 test files in `t/60-scripting/` |

**New features:**
- `multi(callback)`: Callback-based transactions
- `watch_multi(keys, callback)`: Optimistic locking pattern
- Manual `watch/unwatch/multi_start/exec/discard`
- `in_multi` and `watching` state tracking for pool cleanliness
- `evalsha_or_eval`: Automatic NOSCRIPT fallback
- `script(code)`: Reusable script objects with SHA caching

**Total new files:** 12
**Estimated tests:** 100+ assertions

---

## Next Phase

After Phase 3 is complete, Phase 4 will cover:
- **Task 12:** Blocking Commands (BLPOP, BRPOP, BLMOVE)
- **Task 13:** SCAN Iterators
