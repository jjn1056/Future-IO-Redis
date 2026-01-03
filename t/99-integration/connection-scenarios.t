#!/usr/bin/env perl
# Test: Various connection scenarios
use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use Test::Future::IO::Redis qw(init_loop skip_without_redis await_f cleanup_keys);

my $loop = init_loop();

SKIP: {
    my $redis = skip_without_redis();

    subtest 'reconnect after disconnect' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # Verify connection works
        my $pong = await_f($r->ping);
        is($pong, 'PONG', 'initial ping works');

        # Disconnect and reconnect
        $r->disconnect;
        await_f($r->connect);

        $pong = await_f($r->ping);
        is($pong, 'PONG', 'ping after reconnect works');

        $r->disconnect;
    };

    subtest 'multiple sequential connections' => sub {
        for my $i (1..5) {
            my $r = Future::IO::Redis->new(
                host => $ENV{REDIS_HOST} // 'localhost',
            );
            await_f($r->connect);

            my $result = await_f($r->set("conntest:$i", "value$i"));
            is($result, 'OK', "connection $i SET works");

            my $val = await_f($r->get("conntest:$i"));
            is($val, "value$i", "connection $i GET works");

            cleanup_keys($r, "conntest:$i");
            $r->disconnect;
        }
        pass('completed 5 sequential connections');
    };

    subtest 'connection with timeout' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 5,
            read_timeout => 5,
        );
        await_f($r->connect);

        my $pong = await_f($r->ping);
        is($pong, 'PONG', 'connection with timeouts works');

        $r->disconnect;
    };

    subtest 'database selection' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            database => 1,
        );
        await_f($r->connect);

        # Set a key in database 1
        await_f($r->set('dbtest:key', 'in_db1'));

        # Connect to database 0 and verify key doesn't exist
        my $r0 = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
            database => 0,
        );
        await_f($r0->connect);

        my $val0 = await_f($r0->get('dbtest:key'));
        ok(!defined $val0, 'key not in database 0');

        # Verify key exists in database 1
        my $val1 = await_f($r->get('dbtest:key'));
        is($val1, 'in_db1', 'key exists in database 1');

        cleanup_keys($r, 'dbtest:*');
        $r->disconnect;
        $r0->disconnect;
    };

    subtest 'rapid connect/disconnect cycles' => sub {
        for my $i (1..10) {
            my $r = Future::IO::Redis->new(
                host => $ENV{REDIS_HOST} // 'localhost',
            );
            await_f($r->connect);
            await_f($r->ping);
            $r->disconnect;
        }
        pass('completed 10 rapid connect/disconnect cycles');
    };

    $redis->disconnect;
}

done_testing;
