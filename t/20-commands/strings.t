# t/20-commands/strings.t
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

    # Cleanup test keys
    await_f($redis->del('test:str1', 'test:str2', 'test:counter'));

    subtest 'GET and SET' => sub {
        my $result = await_f($redis->set('test:str1', 'hello'));
        is($result, 'OK', 'SET returns OK');

        my $value = await_f($redis->get('test:str1'));
        is($value, 'hello', 'GET returns value');
    };

    subtest 'SET with options' => sub {
        my $result = await_f($redis->set('test:str2', 'world', 'EX', 60));
        is($result, 'OK', 'SET with EX returns OK');

        my $ttl = await_f($redis->ttl('test:str2'));
        ok($ttl > 0 && $ttl <= 60, 'TTL set correctly');
    };

    subtest 'INCR and DECR' => sub {
        await_f($redis->set('test:counter', '10'));

        my $result = await_f($redis->incr('test:counter'));
        is($result, 11, 'INCR returns new value');

        $result = await_f($redis->decr('test:counter'));
        is($result, 10, 'DECR returns new value');

        $result = await_f($redis->incrby('test:counter', 5));
        is($result, 15, 'INCRBY returns new value');
    };

    subtest 'APPEND and STRLEN' => sub {
        await_f($redis->set('test:str1', 'hello'));

        my $len = await_f($redis->append('test:str1', ' world'));
        is($len, 11, 'APPEND returns new length');

        my $value = await_f($redis->get('test:str1'));
        is($value, 'hello world', 'APPEND concatenated correctly');

        $len = await_f($redis->strlen('test:str1'));
        is($len, 11, 'STRLEN returns length');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Run 100 SET/GET pairs
        for my $i (1..100) {
            await_f($redis->set("test:nb:$i", "value$i"));
            await_f($redis->get("test:nb:$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 5, "Event loop ticked " . scalar(@ticks) . " times during 200 commands");

        # Cleanup
        await_f($redis->del(map { "test:nb:$_" } 1..100));
    };

    # Cleanup
    await_f($redis->del('test:str1', 'test:str2', 'test:counter'));
}

done_testing;
