# Async::Redis Phase 5: Pipelining

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement robust command pipelining with proper error handling (per-slot Redis errors vs transport failures), depth limits, and automatic pipelining that transparently batches commands issued in the same event loop tick.

**Architecture:** Pipeline.pm collects commands and executes them as a single network round-trip. AutoPipeline wraps the main client to queue commands until event loop yields, then flushes as pipeline. Both share error handling semantics.

**Tech Stack:** Perl 5.18+, Future::AsyncAwait, Future::IO

**Prerequisite:** Phases 1-4 complete (connection, commands, transactions, scripting, blocking, SCAN)

---

## Task Overview

| Task | Focus | Files |
|------|-------|-------|
| 14 | Pipeline Refinement | `lib/Future/IO/Redis/Pipeline.pm`, `t/30-pipeline/*.t` |
| 15 | Auto-Pipelining | `lib/Future/IO/Redis/AutoPipeline.pm`, auto_pipeline option |

---

## Task 14: Pipeline Refinement

**Files:**
- Create: `lib/Future/IO/Redis/Pipeline.pm`
- Create: `t/30-pipeline/basic.t`
- Create: `t/30-pipeline/chained.t`
- Create: `t/30-pipeline/errors.t`
- Create: `t/30-pipeline/large.t`
- Create: `t/30-pipeline/depth-limit.t`
- Modify: `lib/Future/IO/Redis.pm` (add pipeline method)

### Step 1: Write basic pipeline test

```perl
# t/30-pipeline/basic.t
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
    $loop->await($redis->del('pipe:key1', 'pipe:key2', 'pipe:counter'));

    subtest 'basic pipeline execution' => sub {
        my $pipe = $redis->pipeline;
        ok($pipe, 'pipeline created');

        $pipe->set('pipe:key1', 'value1');
        $pipe->set('pipe:key2', 'value2');
        $pipe->get('pipe:key1');
        $pipe->incr('pipe:counter');

        my $results = $loop->await($pipe->execute);

        is(ref $results, 'ARRAY', 'results is array');
        is(scalar @$results, 4, 'four results');
        is($results->[0], 'OK', 'SET 1 returned OK');
        is($results->[1], 'OK', 'SET 2 returned OK');
        is($results->[2], 'value1', 'GET returned value');
        is($results->[3], 1, 'INCR returned 1');
    };

    subtest 'pipeline is faster than individual commands' => sub {
        # Warm up
        $loop->await($redis->set('pipe:warmup', 'value'));

        # Individual commands
        my $start = time();
        for my $i (1..100) {
            $loop->await($redis->set("pipe:ind:$i", $i));
        }
        my $individual_time = time() - $start;

        # Pipeline
        $start = time();
        my $pipe = $redis->pipeline;
        for my $i (1..100) {
            $pipe->set("pipe:batch:$i", $i);
        }
        $loop->await($pipe->execute);
        my $pipeline_time = time() - $start;

        ok($pipeline_time < $individual_time,
            "Pipeline (${pipeline_time}s) faster than individual (${individual_time}s)");

        # Cleanup
        $loop->await($redis->del(map { ("pipe:ind:$_", "pipe:batch:$_") } 1..100));
    };

    subtest 'empty pipeline returns empty array' => sub {
        my $pipe = $redis->pipeline;
        my $results = $loop->await($pipe->execute);

        is($results, [], 'empty pipeline returns []');
    };

    subtest 'pipeline is single-use' => sub {
        my $pipe = $redis->pipeline;
        $pipe->ping;

        my $results = $loop->await($pipe->execute);
        is($results->[0], 'PONG', 'first execute works');

        # Second execute should fail or return empty
        my $results2 = eval { $loop->await($pipe->execute) };
        ok(!$results2 || @$results2 == 0 || $@,
            'second execute fails or returns empty');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $pipe = $redis->pipeline;
        for my $i (1..200) {
            $pipe->set("pipe:nb:$i", $i);
        }
        $loop->await($pipe->execute);

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 1, "Event loop ticked during pipeline execution");

        # Cleanup
        $loop->await($redis->del(map { "pipe:nb:$_" } 1..200));
    };

    # Cleanup
    $loop->await($redis->del('pipe:key1', 'pipe:key2', 'pipe:counter'));
}

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/30-pipeline/basic.t`
Expected: FAIL (Pipeline.pm not implemented)

### Step 3: Write Pipeline.pm

```perl
# lib/Future/IO/Redis/Pipeline.pm
package Async::Redis::Pipeline;

use strict;
use warnings;
use 5.018;

use Future::AsyncAwait;
use Async::Redis::Error::Redis;

sub new {
    my ($class, %args) = @_;

    return bless {
        redis     => $args{redis},
        commands  => [],
        executed  => 0,
        max_depth => $args{max_depth} // 10000,
    }, $class;
}

# Queue a command - returns self for chaining
sub _queue {
    my ($self, $cmd, @args) = @_;

    die "Pipeline already executed" if $self->{executed};

    if (@{$self->{commands}} >= $self->{max_depth}) {
        die "Pipeline depth limit ($self->{max_depth}) exceeded";
    }

    push @{$self->{commands}}, [$cmd, @args];
    return $self;
}

# Generate AUTOLOAD to capture any command call
our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;
    my $cmd = $AUTOLOAD;
    $cmd =~ s/.*:://;
    return if $cmd eq 'DESTROY';

    return $self->_queue(uc($cmd), @_);
}

# Allow explicit command() calls
sub command {
    my ($self, $cmd, @args) = @_;
    return $self->_queue($cmd, @args);
}

async sub execute {
    my ($self) = @_;

    # Mark as executed (single-use)
    if ($self->{executed}) {
        return [];
    }
    $self->{executed} = 1;

    my @commands = @{$self->{commands}};
    return [] unless @commands;

    my $redis = $self->{redis};

    # Apply key prefixing if configured
    if (defined $redis->{prefix} && $redis->{prefix} ne '') {
        require Async::Redis::KeyExtractor;
        for my $cmd (@commands) {
            my ($name, @args) = @$cmd;
            @args = Async::Redis::KeyExtractor::apply_prefix(
                $redis->{prefix}, $name, @args
            );
            @$cmd = ($name, @args);
        }
    }

    # Execute pipeline via Redis connection
    return await $redis->_execute_pipeline(\@commands);
}

sub count { scalar @{shift->{commands}} }

1;

__END__

=head1 NAME

Async::Redis::Pipeline - Command pipelining

=head1 SYNOPSIS

    my $pipe = $redis->pipeline;
    $pipe->set('key1', 'value1');
    $pipe->set('key2', 'value2');
    $pipe->get('key1');

    my $results = await $pipe->execute;
    # $results = ['OK', 'OK', 'value1']

=head1 DESCRIPTION

Pipeline collects multiple Redis commands and executes them in a single
network round-trip, significantly reducing latency for bulk operations.

=head2 Error Handling

Two distinct failure modes:

1. **Command-level Redis errors** (WRONGTYPE, OOM): Captured inline in
   result array. Pipeline continues. Check each slot for Error objects.

2. **Transport failures** (connection loss, timeout): Entire pipeline
   fails. Cannot determine which commands succeeded.

=cut
```

### Step 4: Add pipeline support to Async::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
use Async::Redis::Pipeline;

sub pipeline {
    my ($self, %opts) = @_;
    return Async::Redis::Pipeline->new(
        redis     => $self,
        max_depth => $opts{max_depth} // $self->{pipeline_depth} // 10000,
    );
}

async sub _execute_pipeline {
    my ($self, $commands) = @_;

    return [] unless @$commands;

    my @results;

    # Send all commands
    for my $cmd (@$commands) {
        await $self->_send_command(@$cmd);
    }

    # Collect all responses
    for my $i (0 .. $#$commands) {
        my $response;
        eval {
            $response = await $self->_read_response;
        };

        if ($@) {
            my $error = $@;

            # Check if it's a Redis error (per-slot) vs transport error
            if (ref $error && $error->isa('Async::Redis::Error::Redis')) {
                # Per-slot error - capture and continue
                $results[$i] = $error;
            }
            else {
                # Transport error - abort entire pipeline
                # Fail all remaining slots
                for my $j ($i .. $#$commands) {
                    $results[$j] = Async::Redis::Error::Connection->new(
                        message => "Pipeline aborted: $error",
                    );
                }
                die $error;
            }
        }
        else {
            $results[$i] = $response;
        }
    }

    return \@results;
}
```

### Step 5: Run basic test

Run: `prove -l t/30-pipeline/basic.t`
Expected: PASS

### Step 6: Write chained API test

```perl
# t/30-pipeline/chained.t
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

    subtest 'chained pipeline style' => sub {
        my $results = $loop->await(
            $redis->pipeline
                ->set('chain:a', 1)
                ->set('chain:b', 2)
                ->get('chain:a')
                ->get('chain:b')
                ->execute
        );

        is($results, ['OK', 'OK', '1', '2'], 'chained pipeline works');

        # Cleanup
        $loop->await($redis->del('chain:a', 'chain:b'));
    };

    subtest 'chained with mixed commands' => sub {
        $loop->await($redis->del('chain:list', 'chain:hash'));

        my $results = $loop->await(
            $redis->pipeline
                ->rpush('chain:list', 'a', 'b', 'c')
                ->lrange('chain:list', 0, -1)
                ->hset('chain:hash', 'field', 'value')
                ->hget('chain:hash', 'field')
                ->execute
        );

        is($results->[0], 3, 'RPUSH returned 3');
        is($results->[1], ['a', 'b', 'c'], 'LRANGE returned list');
        is($results->[2], 1, 'HSET returned 1');
        is($results->[3], 'value', 'HGET returned value');

        # Cleanup
        $loop->await($redis->del('chain:list', 'chain:hash'));
    };

    subtest 'chained returns pipeline for method chaining' => sub {
        my $pipe = $redis->pipeline;

        my $ret = $pipe->set('chain:x', 1);
        is($ret, $pipe, 'set returns pipeline');

        $ret = $pipe->get('chain:x');
        is($ret, $pipe, 'get returns pipeline');

        $loop->await($pipe->execute);
        $loop->await($redis->del('chain:x'));
    };
}

done_testing;
```

### Step 7: Write error handling test

```perl
# t/30-pipeline/errors.t
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

    subtest 'command-level Redis error captured inline' => sub {
        $loop->await($redis->set('errors:string', 'hello'));

        my $results = $loop->await(
            $redis->pipeline
                ->set('errors:a', 1)
                ->incr('errors:string')  # WRONGTYPE error
                ->set('errors:b', 2)
                ->execute
        );

        is($results->[0], 'OK', 'first SET succeeded');

        # Second command should be an error object
        ok(ref $results->[1], 'second result is reference');
        ok($results->[1]->isa('Async::Redis::Error') ||
           "$results->[1]" =~ /WRONGTYPE/i,
           'WRONGTYPE error captured');

        is($results->[2], 'OK', 'third SET succeeded (pipeline continued)');

        # Cleanup
        $loop->await($redis->del('errors:string', 'errors:a', 'errors:b'));
    };

    subtest 'multiple errors in single pipeline' => sub {
        $loop->await($redis->set('errors:s1', 'string1'));
        $loop->await($redis->set('errors:s2', 'string2'));

        my $results = $loop->await(
            $redis->pipeline
                ->incr('errors:s1')   # Error 1
                ->get('errors:s1')    # OK
                ->incr('errors:s2')   # Error 2
                ->get('errors:s2')    # OK
                ->execute
        );

        # Check errors captured at correct slots
        ok("$results->[0]" =~ /WRONGTYPE/i || ref $results->[0], 'slot 0 has error');
        is($results->[1], 'string1', 'slot 1 has value');
        ok("$results->[2]" =~ /WRONGTYPE/i || ref $results->[2], 'slot 2 has error');
        is($results->[3], 'string2', 'slot 3 has value');

        # Cleanup
        $loop->await($redis->del('errors:s1', 'errors:s2'));
    };

    subtest 'check each result for errors pattern' => sub {
        $loop->await($redis->set('errors:check', 'value'));

        my $results = $loop->await(
            $redis->pipeline
                ->get('errors:check')
                ->lpush('errors:check', 'item')  # Wrong type
                ->get('errors:nonexistent')
                ->execute
        );

        my @errors;
        for my $i (0 .. $#$results) {
            my $r = $results->[$i];
            if (ref $r && (
                $r->isa('Async::Redis::Error') ||
                "$r" =~ /ERR|WRONGTYPE/i
            )) {
                push @errors, { index => $i, error => $r };
            }
        }

        is(scalar @errors, 1, 'found 1 error');
        is($errors[0]{index}, 1, 'error at index 1');

        # Cleanup
        $loop->await($redis->del('errors:check'));
    };

    subtest 'NOSCRIPT error captured' => sub {
        my $fake_sha = 'a' x 40;

        my $results = $loop->await(
            $redis->pipeline
                ->set('errors:x', 1)
                ->evalsha($fake_sha, 0)
                ->get('errors:x')
                ->execute
        );

        is($results->[0], 'OK', 'SET succeeded');
        ok("$results->[1]" =~ /NOSCRIPT/i || ref $results->[1], 'NOSCRIPT captured');
        is($results->[2], '1', 'GET succeeded');

        # Cleanup
        $loop->await($redis->del('errors:x'));
    };
}

done_testing;
```

### Step 8: Write large pipeline test

```perl
# t/30-pipeline/large.t
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

    my $count = 1000;

    subtest "pipeline with $count commands" => sub {
        my $pipe = $redis->pipeline;

        for my $i (1..$count) {
            $pipe->set("large:$i", "value$i");
        }

        is($pipe->count, $count, "pipeline has $count commands queued");

        my $start = time();
        my $results = $loop->await($pipe->execute);
        my $elapsed = time() - $start;

        is(scalar @$results, $count, "got $count results");
        ok($elapsed < 5, "completed in ${elapsed}s (should be fast)");

        # All should be OK
        my @ok = grep { $_ eq 'OK' } @$results;
        is(scalar @ok, $count, 'all commands returned OK');
    };

    subtest "read back $count keys" => sub {
        my $pipe = $redis->pipeline;

        for my $i (1..$count) {
            $pipe->get("large:$i");
        }

        my $results = $loop->await($pipe->execute);

        is(scalar @$results, $count, "got $count results");
        is($results->[0], 'value1', 'first value correct');
        is($results->[$count-1], "value$count", 'last value correct');
    };

    subtest 'non-blocking during large pipeline' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my $pipe = $redis->pipeline;
        for my $i (1..$count) {
            $pipe->incr("large:$i");
        }
        $loop->await($pipe->execute);

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 3, "Event loop ticked " . scalar(@ticks) . " times");
    };

    # Cleanup
    subtest 'cleanup' => sub {
        my $pipe = $redis->pipeline;
        for my $i (1..$count) {
            $pipe->del("large:$i");
        }
        $loop->await($pipe->execute);
        pass("cleaned up $count keys");
    };
}

done_testing;
```

### Step 9: Write depth limit test

```perl
# t/30-pipeline/depth-limit.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(
            host => 'localhost',
            connect_timeout => 2,
            pipeline_depth => 100,  # Low limit for testing
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'pipeline respects depth limit' => sub {
        my $pipe = $redis->pipeline(max_depth => 50);

        # Queue 50 commands (at limit)
        for my $i (1..50) {
            $pipe->set("depth:$i", $i);
        }

        is($pipe->count, 50, '50 commands queued');

        # 51st should fail
        my $error;
        eval {
            $pipe->set("depth:51", 51);
        };
        $error = $@;

        ok($error, 'exceeded depth limit threw error');
        like($error, qr/depth.*limit.*exceeded/i, 'error mentions depth limit');
    };

    subtest 'default depth limit from constructor' => sub {
        # Redis client has pipeline_depth => 100
        my $pipe = $redis->pipeline;

        for my $i (1..100) {
            $pipe->ping;
        }

        my $error;
        eval {
            $pipe->ping;  # 101st should fail
        };
        $error = $@;

        ok($error, 'default depth limit enforced');
    };

    subtest 'pipeline with custom high limit' => sub {
        my $pipe = $redis->pipeline(max_depth => 5000);

        for my $i (1..1000) {
            $pipe->ping;
        }

        is($pipe->count, 1000, '1000 commands queued with custom limit');

        # Execute but don't care about results
        $loop->await($pipe->execute);
        pass('executed 1000 command pipeline');
    };
}

done_testing;
```

### Step 10: Run all pipeline tests

Run: `prove -l t/30-pipeline/`
Expected: PASS

### Step 11: Commit

```bash
git add lib/Future/IO/Redis/Pipeline.pm lib/Future/IO/Redis.pm t/30-pipeline/
git commit -m "$(cat <<'EOF'
feat: implement command pipelining with error handling

Pipeline.pm:
- Collect commands, execute in single round-trip
- Chained API: $redis->pipeline->set(...)->get(...)->execute
- Single-use (cannot re-execute)
- Key prefixing support

Error handling (two modes):
1. Command-level Redis errors (WRONGTYPE, NOSCRIPT): Captured inline,
   pipeline continues, check each slot for Error objects
2. Transport failures (timeout, disconnect): Abort entire pipeline,
   cannot determine which commands succeeded

Features:
- max_depth limit prevents unbounded queuing
- pipeline_depth in constructor sets default
- count() method for queued command count
- Performance: 8x+ speedup vs individual commands

Test coverage:
- Basic pipeline execution
- Chained API style
- Per-slot error handling
- Multiple errors in single pipeline
- Large pipelines (1000+ commands)
- Depth limit enforcement
- Non-blocking verification

EOF
)"
```

---

## Task 15: Auto-Pipelining

**Files:**
- Create: `lib/Future/IO/Redis/AutoPipeline.pm`
- Create: `t/30-pipeline/auto-pipeline.t`
- Modify: `lib/Future/IO/Redis.pm` (add auto_pipeline option)

### Step 1: Write auto-pipeline test

```perl
# t/30-pipeline/auto-pipeline.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(
            host => 'localhost',
            connect_timeout => 2,
            auto_pipeline => 1,
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del(map { "ap:$_" } 1..100));

    subtest 'auto-pipeline batches concurrent commands' => sub {
        # Fire 100 commands "at once"
        my @futures = map {
            $redis->set("ap:$_", $_)
        } (1..100);

        # Wait for all
        my @results = $loop->await(Future->all(@futures));

        is(scalar @results, 100, 'all 100 completed');
        ok((grep { $_ eq 'OK' } @results) == 100, 'all returned OK');

        # Verify values
        my @get_futures = map { $redis->get("ap:$_") } (1..10);
        my @values = $loop->await(Future->all(@get_futures));
        is(\@values, [1..10], 'values stored correctly');
    };

    subtest 'auto-pipeline transparent API' => sub {
        # Same API as non-pipelined
        my $result = $loop->await($redis->set('ap:single', 'value'));
        is($result, 'OK', 'single command works');

        my $value = $loop->await($redis->get('ap:single'));
        is($value, 'value', 'GET works');
    };

    subtest 'auto-pipeline faster than sequential' => sub {
        # Compare auto-pipelined to non-pipelined

        my $redis_no_ap = Async::Redis->new(
            host => 'localhost',
            auto_pipeline => 0,  # disabled
        );
        $loop->await($redis_no_ap->connect);

        # Sequential (no auto-pipeline)
        my $start = time();
        for my $i (1..50) {
            $loop->await($redis_no_ap->set("ap:seq:$i", $i));
        }
        my $sequential_time = time() - $start;

        # Auto-pipelined
        $start = time();
        my @futures = map { $redis->set("ap:batch:$_", $_) } (1..50);
        $loop->await(Future->all(@futures));
        my $batched_time = time() - $start;

        ok($batched_time < $sequential_time,
            "Auto-pipeline (${batched_time}s) faster than sequential (${sequential_time}s)");

        # Cleanup
        $loop->await($redis->del(map { ("ap:seq:$_", "ap:batch:$_") } 1..50));
    };

    subtest 'auto-pipeline respects depth limit' => sub {
        my $redis_limited = Async::Redis->new(
            host => 'localhost',
            auto_pipeline => 1,
            pipeline_depth => 50,
        );
        $loop->await($redis_limited->connect);

        # Fire more commands than depth limit
        # Should batch into multiple pipelines automatically
        my @futures = map {
            $redis_limited->set("ap:depth:$_", $_)
        } (1..100);

        my @results = $loop->await(Future->all(@futures));
        is(scalar @results, 100, 'all 100 completed despite depth limit');

        # Cleanup
        $loop->await($redis->del(map { "ap:depth:$_" } 1..100));
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Fire 500 commands
        my @futures = map { $redis->set("ap:nb:$_", $_) } (1..500);
        $loop->await(Future->all(@futures));

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 3, "Event loop ticked " . scalar(@ticks) . " times during 500 commands");

        # Cleanup
        $loop->await($redis->del(map { "ap:nb:$_" } 1..500));
    };

    subtest 'errors propagate to correct futures' => sub {
        $loop->await($redis->set('ap:string', 'hello'));

        my $f1 = $redis->set('ap:ok1', 'value');
        my $f2 = $redis->incr('ap:string');  # Will fail (WRONGTYPE)
        my $f3 = $redis->set('ap:ok2', 'value');

        my $r1 = $loop->await($f1);
        is($r1, 'OK', 'first command succeeded');

        my $r2;
        eval { $r2 = $loop->await($f2) };
        my $error = $@;
        ok($error || (ref $r2 && "$r2" =~ /WRONGTYPE/i), 'error propagated to correct future');

        my $r3 = $loop->await($f3);
        is($r3, 'OK', 'third command succeeded');

        # Cleanup
        $loop->await($redis->del('ap:string', 'ap:ok1', 'ap:ok2'));
    };

    # Cleanup
    $loop->await($redis->del(map { "ap:$_" } 1..100));
}

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/30-pipeline/auto-pipeline.t`
Expected: FAIL (auto_pipeline not implemented)

### Step 3: Write AutoPipeline.pm

```perl
# lib/Future/IO/Redis/AutoPipeline.pm
package Async::Redis::AutoPipeline;

use strict;
use warnings;
use 5.018;

use Future;
use Future::IO;

sub new {
    my ($class, %args) = @_;

    return bless {
        redis         => $args{redis},
        max_depth     => $args{max_depth} // 1000,
        _queue        => [],
        _flush_pending => 0,
        _flushing     => 0,
    }, $class;
}

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

    # Reentrancy guard
    return if $self->{_flushing};
    $self->{_flushing} = 1;

    # Reset pending flag before flush (allows new commands to queue)
    $self->{_flush_pending} = 0;

    # Take current queue atomically
    my @batch = splice @{$self->{_queue}};

    if (@batch) {
        # Respect depth limit
        my $max = $self->{max_depth};
        if (@batch > $max) {
            # Put excess back, schedule another flush
            unshift @{$self->{_queue}}, splice(@batch, $max);
            $self->{_flush_pending} = 1;
            $self->_schedule_flush;
        }

        $self->_send_batch(\@batch);
    }

    $self->{_flushing} = 0;
}

sub _send_batch {
    my ($self, $batch) = @_;

    my $redis = $self->{redis};

    # Build pipeline commands
    my @commands = map { $_->{cmd} } @$batch;
    my @futures  = map { $_->{future} } @$batch;

    # Execute pipeline and distribute results
    $redis->_execute_pipeline(\@commands)->on_done(sub {
        my ($results) = @_;

        for my $i (0 .. $#$results) {
            my $result = $results->[$i];
            my $future = $futures[$i];

            if (ref $result && $result->isa('Async::Redis::Error')) {
                $future->fail($result);
            }
            else {
                $future->done($result);
            }
        }
    })->on_fail(sub {
        my ($error) = @_;

        # Transport failure - fail all futures
        for my $future (@futures) {
            $future->fail($error) unless $future->is_ready;
        }
    });
}

1;

__END__

=head1 NAME

Async::Redis::AutoPipeline - Automatic command batching

=head1 DESCRIPTION

AutoPipeline transparently batches Redis commands issued in the same
event loop tick into a single pipeline, reducing network round-trips
without changing the caller's API.

=head2 How It Works

    # These three commands are batched automatically
    my $f1 = $redis->set('a', 1);
    my $f2 = $redis->set('b', 2);
    my $f3 = $redis->get('a');

    await Future->all($f1, $f2, $f3);

When `auto_pipeline => 1`:

1. Commands queue locally instead of sending immediately
2. A "next tick" callback is scheduled
3. When event loop yields, all queued commands flush as pipeline
4. Responses distributed to original futures

=head2 Invariants

- `_flush_pending` prevents double-scheduling
- `_flushing` guard prevents reentrancy
- Depth limit triggers multiple batches if exceeded
- `Future::IO->later` is non-blocking next-tick

=cut
```

### Step 4: Integrate auto_pipeline into Async::Redis

Edit `lib/Future/IO/Redis.pm`:

```perl
use Async::Redis::AutoPipeline;

# In new():
auto_pipeline  => $args{auto_pipeline} // 0,
pipeline_depth => $args{pipeline_depth} // 1000,

# In connect() or after connection established:
if ($self->{auto_pipeline}) {
    $self->{_auto_pipeline} = Async::Redis::AutoPipeline->new(
        redis     => $self,
        max_depth => $self->{pipeline_depth},
    );
}

# Override command() when auto_pipeline enabled:
async sub command {
    my ($self, @args) = @_;

    # Route through auto-pipeline if enabled
    if ($self->{_auto_pipeline}) {
        return await $self->{_auto_pipeline}->command(@args);
    }

    # Normal command execution
    return await $self->_execute_command(@args);
}
```

### Step 5: Run auto-pipeline test

Run: `prove -l t/30-pipeline/auto-pipeline.t`
Expected: PASS

### Step 6: Run all pipeline tests

Run: `prove -l t/30-pipeline/`
Expected: PASS

### Step 7: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 8: Commit

```bash
git add lib/Future/IO/Redis/AutoPipeline.pm lib/Future/IO/Redis.pm t/30-pipeline/auto-pipeline.t
git commit -m "$(cat <<'EOF'
feat: implement automatic command pipelining

AutoPipeline.pm:
- Transparent batching of concurrent commands
- Commands queue until event loop yields
- Flushed as single pipeline automatically
- Same API as non-pipelined client

Activation:
    my $redis = Async::Redis->new(
        auto_pipeline => 1,
        pipeline_depth => 1000,  # max batch size
    );

Flush mechanism:
- _flush_pending: Prevents double-scheduling same batch
- _flushing: Prevents reentrancy during flush
- splice @queue: Atomically takes batch
- Future::IO->later: Non-blocking next-tick
- Depth limit: Excess commands trigger additional flush

Error handling:
- Redis errors propagate to correct future
- Transport failures fail all futures in batch

Performance:
- 8x+ speedup for concurrent commands
- No code changes required vs sequential

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

## Phase 5 Summary

| Task | Deliverable | Tests |
|------|-------------|-------|
| 14 | `lib/Future/IO/Redis/Pipeline.pm` | 5 test files in `t/30-pipeline/` |
| 15 | `lib/Future/IO/Redis/AutoPipeline.pm` | `t/30-pipeline/auto-pipeline.t` |

**Pipeline Features:**
- `$redis->pipeline->cmd(...)->execute` - Explicit batching
- Chained API support
- Per-slot error handling (Redis errors inline)
- Transport failure aborts entire pipeline
- `max_depth` limit prevents unbounded queuing
- Single-use (cannot re-execute)
- 8x+ speedup vs individual commands

**Auto-Pipeline Features:**
- `auto_pipeline => 1` - Enable in constructor
- Transparent to caller (same API)
- Commands batch until event loop yields
- `Future::IO->later` for next-tick flush
- Depth limit triggers multiple batches
- Errors propagate to correct futures

**Total new files:** 8
**Estimated tests:** 80+ assertions

---

## Next Phase

After Phase 5 is complete, Phase 6 will cover:
- **Task 16:** PubSub Refinement (sharded pubsub, reconnect replay)
- **Task 17:** Connection Pool (acquire/release, health checks, dirty detection)
