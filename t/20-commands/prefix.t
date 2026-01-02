# t/20-commands/prefix.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
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
        my $r = Future::IO::Redis->new(
            host   => $ENV{REDIS_HOST} // 'localhost',
            prefix => 'test:prefix:',
            connect_timeout => 2,
        );
        await_f($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'prefix applied to SET/GET' => sub {
        await_f($redis->set('key1', 'value1'));

        # Value should be stored under prefixed key
        my $raw_redis = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw_redis->connect);

        my $value = await_f($raw_redis->get('test:prefix:key1'));
        is($value, 'value1', 'key stored with prefix');

        # Our prefixed client should find it
        $value = await_f($redis->get('key1'));
        is($value, 'value1', 'prefixed GET works');

        # Cleanup via raw connection
        await_f($raw_redis->del('test:prefix:key1'));
    };

    subtest 'prefix applied to MGET' => sub {
        my $raw_redis = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw_redis->connect);

        # Set up keys with prefix
        await_f($raw_redis->set('test:prefix:a', '1'));
        await_f($raw_redis->set('test:prefix:b', '2'));
        await_f($raw_redis->set('test:prefix:c', '3'));

        # MGET with prefixed client
        my $values = await_f($redis->mget('a', 'b', 'c'));
        is($values, ['1', '2', '3'], 'MGET with prefix works');

        # Cleanup
        await_f($raw_redis->del('test:prefix:a', 'test:prefix:b', 'test:prefix:c'));
    };

    subtest 'prefix NOT applied to values' => sub {
        await_f($redis->set('key2', 'my:value:with:colons'));

        my $raw_redis = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw_redis->connect);

        my $value = await_f($raw_redis->get('test:prefix:key2'));
        is($value, 'my:value:with:colons', 'value not prefixed');

        # Cleanup
        await_f($raw_redis->del('test:prefix:key2'));
    };

    subtest 'prefix in MSET - keys only, not values' => sub {
        await_f($redis->mset('x', 'val:x', 'y', 'val:y'));

        my $raw_redis = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw_redis->connect);

        my $x = await_f($raw_redis->get('test:prefix:x'));
        my $y = await_f($raw_redis->get('test:prefix:y'));
        is($x, 'val:x', 'x value unchanged');
        is($y, 'val:y', 'y value unchanged');

        # Cleanup
        await_f($raw_redis->del('test:prefix:x', 'test:prefix:y'));
    };

    subtest 'prefix in hash commands' => sub {
        await_f($redis->hset('myhash', 'field1', 'value1'));

        my $raw_redis = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw_redis->connect);

        # Check it's stored with prefix
        my $value = await_f($raw_redis->hget('test:prefix:myhash', 'field1'));
        is($value, 'value1', 'hash stored with prefixed key');

        # Field name should NOT be prefixed
        my $exists = await_f($raw_redis->hexists('test:prefix:myhash', 'field1'));
        is($exists, 1, 'field name not prefixed');

        # Cleanup
        await_f($raw_redis->del('test:prefix:myhash'));
    };

    subtest 'DEL with multiple keys' => sub {
        my $raw_redis = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($raw_redis->connect);

        await_f($raw_redis->set('test:prefix:d1', '1'));
        await_f($raw_redis->set('test:prefix:d2', '2'));
        await_f($raw_redis->set('test:prefix:d3', '3'));

        # Delete via prefixed client
        my $deleted = await_f($redis->del('d1', 'd2', 'd3'));
        is($deleted, 3, 'DEL with prefix deleted 3 keys');

        # Verify deleted
        my $exists = await_f($raw_redis->exists('test:prefix:d1'));
        is($exists, 0, 'key deleted');
    };

    subtest 'no prefix when disabled' => sub {
        my $no_prefix = Future::IO::Redis->new(host => $ENV{REDIS_HOST} // 'localhost');
        await_f($no_prefix->connect);

        await_f($no_prefix->set('raw:key', 'value'));
        my $value = await_f($no_prefix->get('raw:key'));
        is($value, 'value', 'no prefix client works');

        # Cleanup
        await_f($no_prefix->del('raw:key'));
    };
}

done_testing;
