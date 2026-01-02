# t/20-commands/hashes.t
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
    await_f($redis->del('test:hash'));

    subtest 'HSET and HGET' => sub {
        my $result = await_f($redis->hset('test:hash', 'field1', 'value1'));
        ok($result >= 0, 'HSET returns count');

        my $value = await_f($redis->hget('test:hash', 'field1'));
        is($value, 'value1', 'HGET returns value');
    };

    subtest 'HMSET and HMGET' => sub {
        await_f($redis->hmset('test:hash',
            'a', '1',
            'b', '2',
            'c', '3',
        ));

        my $values = await_f($redis->hmget('test:hash', 'a', 'b', 'c'));
        is($values, ['1', '2', '3'], 'HMGET returns values in order');
    };

    subtest 'HGETALL returns hash' => sub {
        my $hash = await_f($redis->hgetall('test:hash'));
        is(ref $hash, 'HASH', 'HGETALL returns hashref');
        is($hash->{field1}, 'value1', 'contains field1');
        is($hash->{a}, '1', 'contains a');
    };

    subtest 'HEXISTS and HDEL' => sub {
        my $exists = await_f($redis->hexists('test:hash', 'field1'));
        is($exists, 1, 'HEXISTS returns 1 for existing field');

        my $deleted = await_f($redis->hdel('test:hash', 'field1'));
        is($deleted, 1, 'HDEL returns count');

        $exists = await_f($redis->hexists('test:hash', 'field1'));
        is($exists, 0, 'HEXISTS returns 0 after delete');
    };

    subtest 'HKEYS, HVALS, HLEN' => sub {
        my $keys = await_f($redis->hkeys('test:hash'));
        ok(@$keys >= 3, 'HKEYS returns keys');

        my $vals = await_f($redis->hvals('test:hash'));
        ok(@$vals >= 3, 'HVALS returns values');

        my $len = await_f($redis->hlen('test:hash'));
        ok($len >= 3, 'HLEN returns count');
    };

    subtest 'HINCRBY' => sub {
        await_f($redis->hset('test:hash', 'counter', '10'));

        my $result = await_f($redis->hincrby('test:hash', 'counter', 5));
        is($result, 15, 'HINCRBY returns new value');
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
            await_f($redis->hset('test:hash', "field$i", "val$i"));
            await_f($redis->hget('test:hash', "field$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 3, "Event loop ticked during hash operations");
    };

    # Cleanup
    await_f($redis->del('test:hash'));
}

done_testing;
