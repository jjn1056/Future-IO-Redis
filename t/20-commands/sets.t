# t/20-commands/sets.t
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
    await_f($redis->del('test:set1', 'test:set2'));

    subtest 'SADD and SMEMBERS' => sub {
        my $added = await_f($redis->sadd('test:set1', 'a', 'b', 'c'));
        is($added, 3, 'SADD returns count');

        my $members = await_f($redis->smembers('test:set1'));
        is([sort @$members], ['a', 'b', 'c'], 'SMEMBERS returns all members');
    };

    subtest 'SISMEMBER and SCARD' => sub {
        my $is = await_f($redis->sismember('test:set1', 'a'));
        is($is, 1, 'SISMEMBER returns 1 for member');

        $is = await_f($redis->sismember('test:set1', 'z'));
        is($is, 0, 'SISMEMBER returns 0 for non-member');

        my $card = await_f($redis->scard('test:set1'));
        is($card, 3, 'SCARD returns cardinality');
    };

    subtest 'SREM' => sub {
        my $removed = await_f($redis->srem('test:set1', 'a'));
        is($removed, 1, 'SREM returns count');

        my $card = await_f($redis->scard('test:set1'));
        is($card, 2, 'cardinality decreased');
    };

    subtest 'SINTER, SUNION, SDIFF' => sub {
        await_f($redis->sadd('test:set1', 'a', 'b', 'c'));
        await_f($redis->sadd('test:set2', 'b', 'c', 'd'));

        my $inter = await_f($redis->sinter('test:set1', 'test:set2'));
        is([sort @$inter], ['b', 'c'], 'SINTER works');

        my $union = await_f($redis->sunion('test:set1', 'test:set2'));
        is([sort @$union], ['a', 'b', 'c', 'd'], 'SUNION works');

        my $diff = await_f($redis->sdiff('test:set1', 'test:set2'));
        is([sort @$diff], ['a'], 'SDIFF works');
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
            await_f($redis->sadd('test:set1', "member$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 2, "Event loop ticked during set operations");
    };

    # Cleanup
    await_f($redis->del('test:set1', 'test:set2'));
}

done_testing;
