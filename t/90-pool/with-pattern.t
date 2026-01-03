# t/90-pool/with-pattern.t
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

    my $pool = Future::IO::Redis::Pool->new(
        host => $ENV{REDIS_HOST} // 'localhost',
        min  => 1,
        max  => 3,
    );

    subtest 'with() returns result' => sub {
        my $result = await_f($pool->with(async sub {
            my ($redis) = @_;
            await $redis->set('with:test', 'hello');
            return await $redis->get('with:test');
        }));

        is($result, 'hello', 'with() returned result');

        # Cleanup
        await_f($pool->with(async sub {
            my ($redis) = @_;
            await $redis->del('with:test');
        }));
    };

    subtest 'with() releases on success' => sub {
        await_f($pool->with(async sub {
            my ($redis) = @_;
            await $redis->ping;
        }));

        my $stats = $pool->stats;
        is($stats->{active}, 0, 'no active connections after with()');
        ok($stats->{idle} >= 1, 'connection returned to pool');
    };

    subtest 'with() releases on exception' => sub {
        my $error;
        eval {
            await_f($pool->with(async sub {
                my ($redis) = @_;
                await $redis->ping;
                die "intentional error";
            }));
        };
        $error = $@;

        like($error, qr/intentional error/, 'exception propagated');

        my $stats = $pool->stats;
        is($stats->{active}, 0, 'connection released despite exception');
    };

    subtest 'with() handles transaction cleanup' => sub {
        # Start transaction but don't complete it
        eval {
            await_f($pool->with(async sub {
                my ($redis) = @_;
                await $redis->multi_start;
                await $redis->incr('with:counter');
                die "transaction interrupted";
            }));
        };

        # Connection was dirty (in_multi), should be destroyed
        # Next acquire should get clean connection
        await_f($pool->with(async sub {
            my ($redis) = @_;
            ok(!$redis->in_multi, 'new connection not in transaction');
            await $redis->ping;
        }));
    };

    subtest 'nested with() calls' => sub {
        my $outer_id;
        my $inner_id;

        await_f($pool->with(async sub {
            my ($redis1) = @_;
            $outer_id = "$redis1";

            # Nested with() should get different connection
            await $pool->with(async sub {
                my ($redis2) = @_;
                $inner_id = "$redis2";
            });
        }));

        isnt($outer_id, $inner_id, 'nested with() used different connections');
    };

    subtest 'concurrent with() calls' => sub {
        my @ids;

        my @futures = map {
            $pool->with(async sub {
                my ($redis) = @_;
                push @ids, "$redis";
                await Future::IO->sleep(0.1);
            })
        } (1..3);

        await_f(Future->needs_all(@futures));

        is(scalar @ids, 3, 'all 3 completed');
        is(scalar(keys %{{ map { $_ => 1 } @ids }}), 3, 'used 3 different connections');
    };
}

done_testing;
