# t/90-pool/dirty-detection.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::AsyncAwait;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis::Pool;
use Future;

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

SKIP: {
    my $test_redis = eval {
        require Future::IO::Redis;
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'is_dirty detects in_multi' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = await_f($pool->acquire);
        ok(!$conn->is_dirty, 'connection starts clean');

        # Start MULTI
        await_f($conn->multi_start);
        ok($conn->in_multi, 'in_multi flag set');
        ok($conn->is_dirty, 'connection is dirty');

        # Don't EXEC/DISCARD - release dirty
        $pool->release($conn);

        # Should be destroyed
        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty connection destroyed');
    };

    subtest 'is_dirty detects watching' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = await_f($pool->acquire);
        await_f($conn->watch('dirty:key'));

        ok($conn->watching, 'watching flag set');
        ok($conn->is_dirty, 'connection is dirty');

        $pool->release($conn);

        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty connection destroyed');
    };

    subtest 'is_dirty detects in_pubsub' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = await_f($pool->acquire);
        await_f($conn->subscribe('dirty:channel'));

        ok($conn->in_pubsub, 'in_pubsub flag set');
        ok($conn->is_dirty, 'connection is dirty');

        $pool->release($conn);

        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty pubsub connection destroyed');
    };

    subtest 'clean connection reused' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn1 = await_f($pool->acquire);
        my $id1 = "$conn1";
        await_f($conn1->ping);  # Normal command
        ok(!$conn1->is_dirty, 'connection still clean');
        $pool->release($conn1);

        my $conn2 = await_f($pool->acquire);
        my $id2 = "$conn2";

        is($id1, $id2, 'clean connection was reused');

        $pool->release($conn2);
    };

    subtest 'properly completed transaction is clean' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = await_f($pool->acquire);
        await_f($conn->multi_start);
        ok($conn->in_multi, 'in transaction');

        await_f($conn->command('INCR', 'dirty:counter'));
        await_f($conn->exec);

        ok(!$conn->in_multi, 'transaction completed');
        ok(!$conn->is_dirty, 'connection is clean');

        my $id = "$conn";
        $pool->release($conn);

        my $conn2 = await_f($pool->acquire);
        is("$conn2", $id, 'connection reused after clean transaction');

        $pool->release($conn2);
        await_f($pool->with(async sub {
            my ($r) = @_;
            await $r->del('dirty:counter');
        }));
    };

    subtest 'discard clears in_multi' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = await_f($pool->acquire);
        await_f($conn->multi_start);
        ok($conn->in_multi, 'in transaction');

        await_f($conn->discard);
        ok(!$conn->in_multi, 'DISCARD cleared in_multi');
        ok(!$conn->is_dirty, 'connection is clean');

        $pool->release($conn);
    };

    subtest 'unwatch clears watching' => sub {
        my $pool = Future::IO::Redis::Pool->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );

        my $conn = await_f($pool->acquire);
        await_f($conn->watch('dirty:key'));
        ok($conn->watching, 'watching');

        await_f($conn->unwatch);
        ok(!$conn->watching, 'UNWATCH cleared watching');
        ok(!$conn->is_dirty, 'connection is clean');

        $pool->release($conn);
    };
}

done_testing;
