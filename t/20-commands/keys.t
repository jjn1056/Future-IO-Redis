# t/20-commands/keys.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

SKIP: {
    my $redis = eval {
        my $r = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost', connect_timeout => 2);
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    await_f($redis->del('test:key1', 'test:key2', 'test:key3'));

    subtest 'EXISTS' => sub {
        await_f($redis->set('test:key1', 'value'));

        my $exists = await_f($redis->exists('test:key1'));
        is($exists, 1, 'EXISTS returns 1 for existing key');

        $exists = await_f($redis->exists('test:nonexistent'));
        is($exists, 0, 'EXISTS returns 0 for non-existing key');

        # Multiple keys
        await_f($redis->set('test:key2', 'value2'));
        $exists = await_f($redis->exists('test:key1', 'test:key2', 'test:nonexistent'));
        is($exists, 2, 'EXISTS with multiple keys returns count');
    };

    subtest 'DEL' => sub {
        await_f($redis->set('test:key3', 'value3'));

        my $deleted = await_f($redis->del('test:key1', 'test:key2', 'test:key3'));
        is($deleted, 3, 'DEL returns count of deleted keys');

        my $exists = await_f($redis->exists('test:key1'));
        is($exists, 0, 'key deleted');
    };

    subtest 'EXPIRE and TTL' => sub {
        await_f($redis->set('test:key1', 'value'));
        await_f($redis->expire('test:key1', 60));

        my $ttl = await_f($redis->ttl('test:key1'));
        ok($ttl > 0 && $ttl <= 60, "TTL is $ttl (expected 1-60)");

        # Remove expiry
        await_f($redis->persist('test:key1'));
        $ttl = await_f($redis->ttl('test:key1'));
        is($ttl, -1, 'TTL is -1 after PERSIST');
    };

    subtest 'TYPE' => sub {
        await_f($redis->set('test:key1', 'string'));
        my $type = await_f($redis->type('test:key1'));
        is($type, 'string', 'TYPE returns string');

        await_f($redis->rpush('test:key2', 'item'));
        $type = await_f($redis->type('test:key2'));
        is($type, 'list', 'TYPE returns list');
    };

    subtest 'RENAME' => sub {
        await_f($redis->set('test:key1', 'value'));
        await_f($redis->rename('test:key1', 'test:key1:renamed'));

        my $exists = await_f($redis->exists('test:key1'));
        is($exists, 0, 'old key gone');

        $exists = await_f($redis->exists('test:key1:renamed'));
        is($exists, 1, 'new key exists');

        # Cleanup
        await_f($redis->del('test:key1:renamed'));
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        for my $i (1..50) {
            await_f($redis->set("test:nb:$i", "value$i"));
            await_f($redis->exists("test:nb:$i"));
            await_f($redis->del("test:nb:$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 5, "Event loop ticked during key operations");
    };

    # Cleanup
    await_f($redis->del('test:key1', 'test:key2', 'test:key3'));
}

done_testing;
