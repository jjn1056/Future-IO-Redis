#!/usr/bin/env perl
# Benchmark script for Future::IO::Redis
use strict;
use warnings;
use Getopt::Long;
use Time::HiRes qw(time);
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use lib 'lib';
use Future::IO::Redis;

my $host = $ENV{REDIS_HOST} // 'localhost';
my $port = $ENV{REDIS_PORT} // 6379;
my $iterations = 10_000;
my $pipeline_size = 1000;

GetOptions(
    'host=s'     => \$host,
    'port=i'     => \$port,
    'iterations=i' => \$iterations,
    'pipeline=i' => \$pipeline_size,
    'help'       => sub { usage(); exit 0 },
) or usage();

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

print "Future::IO::Redis Benchmark\n";
print "=" x 40, "\n";
print "Host: $host:$port\n";
print "Iterations: $iterations\n";
print "Pipeline size: $pipeline_size\n";
print "=" x 40, "\n\n";

my $redis = Future::IO::Redis->new(
    host => $host,
    port => $port,
);

eval { await_f($redis->connect) };
if ($@) {
    die "Failed to connect to Redis at $host:$port: $@\n";
}

print "Connected to Redis\n\n";

# Benchmark 1: Sequential SET
print "Benchmark: Sequential SET\n";
{
    my $start = time();
    for my $i (1..1000) {
        await_f($redis->set("bench:seq:$i", "value$i"));
    }
    my $elapsed = time() - $start;
    my $ops = 1000 / $elapsed;
    printf "  1000 sequential SETs: %.3fs (%.0f ops/sec)\n\n", $elapsed, $ops;
}

# Benchmark 2: Sequential GET
print "Benchmark: Sequential GET\n";
{
    my $start = time();
    for my $i (1..1000) {
        await_f($redis->get("bench:seq:$i"));
    }
    my $elapsed = time() - $start;
    my $ops = 1000 / $elapsed;
    printf "  1000 sequential GETs: %.3fs (%.0f ops/sec)\n\n", $elapsed, $ops;
}

# Benchmark 3: Pipelined SET
print "Benchmark: Pipelined SET\n";
{
    my $start = time();
    my $total = 0;

    for (my $batch = 0; $batch * $pipeline_size < $iterations; $batch++) {
        my $pipe = $redis->pipeline;
        for my $i (1..$pipeline_size) {
            my $key = "bench:pipe:" . ($batch * $pipeline_size + $i);
            $pipe->set($key, "value$i");
        }
        await_f($pipe->execute);
        $total += $pipeline_size;
    }

    my $elapsed = time() - $start;
    my $ops = $total / $elapsed;
    printf "  %d pipelined SETs (batch %d): %.3fs (%.0f ops/sec)\n\n",
           $total, $pipeline_size, $elapsed, $ops;
}

# Benchmark 4: Pipelined GET
print "Benchmark: Pipelined GET\n";
{
    my $start = time();
    my $total = 0;

    for (my $batch = 0; $batch * $pipeline_size < $iterations; $batch++) {
        my $pipe = $redis->pipeline;
        for my $i (1..$pipeline_size) {
            my $key = "bench:pipe:" . ($batch * $pipeline_size + $i);
            $pipe->get($key);
        }
        await_f($pipe->execute);
        $total += $pipeline_size;
    }

    my $elapsed = time() - $start;
    my $ops = $total / $elapsed;
    printf "  %d pipelined GETs (batch %d): %.3fs (%.0f ops/sec)\n\n",
           $total, $pipeline_size, $elapsed, $ops;
}

# Benchmark 5: Mixed pipeline operations
print "Benchmark: Mixed Pipeline (SET + GET + INCR)\n";
{
    my $start = time();
    my $total = 0;

    for my $batch (1..100) {
        my $pipe = $redis->pipeline;
        for my $i (1..100) {
            my $key = "bench:mix:$batch:$i";
            $pipe->set($key, $i);
            $pipe->get($key);
            $pipe->incr("bench:counter");
        }
        await_f($pipe->execute);
        $total += 300;  # 3 ops per iteration
    }

    my $elapsed = time() - $start;
    my $ops = $total / $elapsed;
    printf "  %d mixed operations: %.3fs (%.0f ops/sec)\n\n", $total, $elapsed, $ops;
}

# Benchmark 6: List operations
print "Benchmark: List Operations (LPUSH/RPUSH/LRANGE)\n";
{
    my $start = time();

    # Push 1000 items
    my $pipe = $redis->pipeline;
    for my $i (1..1000) {
        $pipe->rpush('bench:list', "item$i");
    }
    await_f($pipe->execute);

    # Read all items
    await_f($redis->lrange('bench:list', 0, -1));

    my $elapsed = time() - $start;
    printf "  1000 RPUSHs + LRANGE: %.3fs\n\n", $elapsed;
}

# Benchmark 7: Hash operations
print "Benchmark: Hash Operations (HSET/HGETALL)\n";
{
    my $start = time();

    my $pipe = $redis->pipeline;
    for my $i (1..1000) {
        $pipe->hset('bench:hash', "field$i", "value$i");
    }
    await_f($pipe->execute);

    await_f($redis->hgetall('bench:hash'));

    my $elapsed = time() - $start;
    printf "  1000 HSETs + HGETALL: %.3fs\n\n", $elapsed;
}

# Benchmark 8: Set operations
print "Benchmark: Set Operations (SADD/SMEMBERS)\n";
{
    my $start = time();

    my $pipe = $redis->pipeline;
    for my $i (1..1000) {
        $pipe->sadd('bench:set', "member$i");
    }
    await_f($pipe->execute);

    await_f($redis->smembers('bench:set'));

    my $elapsed = time() - $start;
    printf "  1000 SADDs + SMEMBERS: %.3fs\n\n", $elapsed;
}

# Benchmark 9: Large values
print "Benchmark: Large Values (1KB, 10KB, 100KB)\n";
{
    for my $size (1024, 10240, 102400) {
        my $value = 'x' x $size;
        my $label = $size >= 1024 ? ($size / 1024) . "KB" : "${size}B";

        my $start = time();
        for my $i (1..100) {
            await_f($redis->set("bench:large:$i", $value));
            await_f($redis->get("bench:large:$i"));
        }
        my $elapsed = time() - $start;
        my $ops = 200 / $elapsed;  # 100 SETs + 100 GETs
        printf "  %s values (100 SET+GET): %.3fs (%.0f ops/sec)\n", $label, $elapsed, $ops;
    }
}

# Cleanup
print "\nCleaning up...\n";
my $keys = await_f($redis->keys('bench:*'));
if (@$keys) {
    await_f($redis->del(@$keys));
}

print "Done!\n";
$redis->disconnect;

sub usage {
    print <<'USAGE';
Usage: benchmark.pl [options]

Options:
  --host=HOST       Redis host (default: localhost or REDIS_HOST env)
  --port=PORT       Redis port (default: 6379 or REDIS_PORT env)
  --iterations=N    Number of operations for pipeline tests (default: 10000)
  --pipeline=N      Pipeline batch size (default: 1000)
  --help            Show this help

Example:
  ./scripts/benchmark.pl --host=redis.local --iterations=50000
USAGE
}
