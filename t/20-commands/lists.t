# t/20-commands/lists.t
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
    await_f($redis->del('test:list'));

    subtest 'LPUSH and RPUSH' => sub {
        my $len = await_f($redis->rpush('test:list', 'a', 'b', 'c'));
        is($len, 3, 'RPUSH returns new length');

        $len = await_f($redis->lpush('test:list', 'z'));
        is($len, 4, 'LPUSH returns new length');
    };

    subtest 'LRANGE' => sub {
        my $list = await_f($redis->lrange('test:list', 0, -1));
        is($list, ['z', 'a', 'b', 'c'], 'LRANGE returns full list');

        $list = await_f($redis->lrange('test:list', 0, 1));
        is($list, ['z', 'a'], 'LRANGE with slice');
    };

    subtest 'LPOP and RPOP' => sub {
        my $val = await_f($redis->lpop('test:list'));
        is($val, 'z', 'LPOP returns left element');

        $val = await_f($redis->rpop('test:list'));
        is($val, 'c', 'RPOP returns right element');
    };

    subtest 'LLEN and LINDEX' => sub {
        my $len = await_f($redis->llen('test:list'));
        is($len, 2, 'LLEN returns length');

        my $val = await_f($redis->lindex('test:list', 0));
        is($val, 'a', 'LINDEX returns element at index');
    };

    subtest 'LSET' => sub {
        await_f($redis->lset('test:list', 0, 'A'));
        my $val = await_f($redis->lindex('test:list', 0));
        is($val, 'A', 'LSET modified element');
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
            await_f($redis->rpush('test:list', "item$i"));
        }
        await_f($redis->lrange('test:list', 0, -1));

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 2, "Event loop ticked during list operations");
    };

    # Cleanup
    await_f($redis->del('test:list'));
}

done_testing;
