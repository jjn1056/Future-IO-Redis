#!/usr/bin/env perl
# Test: All Redis data types integration
use strict;
use warnings;
use Test2::V0;
use lib 't/lib';
use Test::Future::IO::Redis qw(init_loop skip_without_redis await_f cleanup_keys);

my $loop = init_loop();

SKIP: {
    my $redis = skip_without_redis();

    subtest 'strings' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # SET/GET
        await_f($r->set('str:key', 'value'));
        is(await_f($r->get('str:key')), 'value', 'GET works');

        # SETNX
        await_f($r->setnx('str:nx', 'first'));
        await_f($r->setnx('str:nx', 'second'));
        is(await_f($r->get('str:nx')), 'first', 'SETNX only sets if not exists');

        # GETSET
        my $old = await_f($r->getset('str:key', 'newvalue'));
        is($old, 'value', 'GETSET returns old value');
        is(await_f($r->get('str:key')), 'newvalue', 'GETSET sets new value');

        # APPEND
        await_f($r->set('str:app', 'hello'));
        await_f($r->append('str:app', ' world'));
        is(await_f($r->get('str:app')), 'hello world', 'APPEND works');

        # STRLEN
        my $len = await_f($r->strlen('str:app'));
        is($len, 11, 'STRLEN correct');

        # MSET/MGET
        await_f($r->mset('str:m1', 'v1', 'str:m2', 'v2', 'str:m3', 'v3'));
        my $vals = await_f($r->mget('str:m1', 'str:m2', 'str:m3'));
        is($vals, ['v1', 'v2', 'v3'], 'MSET/MGET work');

        # INCR/DECR
        await_f($r->set('str:num', '10'));
        is(await_f($r->incr('str:num')), 11, 'INCR works');
        is(await_f($r->decr('str:num')), 10, 'DECR works');
        is(await_f($r->incrby('str:num', 5)), 15, 'INCRBY works');
        is(await_f($r->decrby('str:num', 3)), 12, 'DECRBY works');

        cleanup_keys($r, 'str:*');
        $r->disconnect;
    };

    subtest 'lists' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # LPUSH/RPUSH
        await_f($r->rpush('list:key', 'a', 'b', 'c'));
        await_f($r->lpush('list:key', 'z'));

        # LRANGE
        my $items = await_f($r->lrange('list:key', 0, -1));
        is($items, ['z', 'a', 'b', 'c'], 'LPUSH/RPUSH/LRANGE work');

        # LLEN
        is(await_f($r->llen('list:key')), 4, 'LLEN correct');

        # LINDEX
        is(await_f($r->lindex('list:key', 1)), 'a', 'LINDEX works');

        # LSET
        await_f($r->lset('list:key', 1, 'A'));
        is(await_f($r->lindex('list:key', 1)), 'A', 'LSET works');

        # LPOP/RPOP
        is(await_f($r->lpop('list:key')), 'z', 'LPOP works');
        is(await_f($r->rpop('list:key')), 'c', 'RPOP works');

        # LREM
        await_f($r->rpush('list:rem', 'a', 'b', 'a', 'c', 'a'));
        await_f($r->lrem('list:rem', 2, 'a'));
        my $rem_items = await_f($r->lrange('list:rem', 0, -1));
        is($rem_items, ['b', 'c', 'a'], 'LREM works');

        cleanup_keys($r, 'list:*');
        $r->disconnect;
    };

    subtest 'sets' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # SADD
        await_f($r->sadd('set:key', 'a', 'b', 'c'));

        # SCARD
        is(await_f($r->scard('set:key')), 3, 'SCARD correct');

        # SISMEMBER
        ok(await_f($r->sismember('set:key', 'a')), 'SISMEMBER finds member');
        ok(!await_f($r->sismember('set:key', 'x')), 'SISMEMBER returns false for non-member');

        # SMEMBERS
        my $members = await_f($r->smembers('set:key'));
        is([sort @$members], ['a', 'b', 'c'], 'SMEMBERS returns all');

        # SREM
        await_f($r->srem('set:key', 'b'));
        ok(!await_f($r->sismember('set:key', 'b')), 'SREM removes member');

        # Set operations
        await_f($r->sadd('set:a', '1', '2', '3'));
        await_f($r->sadd('set:b', '2', '3', '4'));

        my $union = await_f($r->sunion('set:a', 'set:b'));
        is([sort @$union], ['1', '2', '3', '4'], 'SUNION works');

        my $inter = await_f($r->sinter('set:a', 'set:b'));
        is([sort @$inter], ['2', '3'], 'SINTER works');

        my $diff = await_f($r->sdiff('set:a', 'set:b'));
        is($diff, ['1'], 'SDIFF works');

        cleanup_keys($r, 'set:*');
        $r->disconnect;
    };

    subtest 'hashes' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # HSET/HGET
        await_f($r->hset('hash:key', 'field1', 'value1'));
        is(await_f($r->hget('hash:key', 'field1')), 'value1', 'HSET/HGET work');

        # HMSET/HMGET
        await_f($r->hmset('hash:key', 'f2', 'v2', 'f3', 'v3'));
        my $vals = await_f($r->hmget('hash:key', 'field1', 'f2', 'f3'));
        is($vals, ['value1', 'v2', 'v3'], 'HMSET/HMGET work');

        # HGETALL
        my $all = await_f($r->hgetall('hash:key'));
        is(ref($all), 'HASH', 'HGETALL returns hash');
        is($all->{field1}, 'value1', 'HGETALL field1 correct');
        is($all->{f2}, 'v2', 'HGETALL f2 correct');

        # HKEYS/HVALS
        my $keys = await_f($r->hkeys('hash:key'));
        is([sort @$keys], ['f2', 'f3', 'field1'], 'HKEYS works');

        my $values = await_f($r->hvals('hash:key'));
        is([sort @$values], ['v2', 'v3', 'value1'], 'HVALS works');

        # HLEN
        is(await_f($r->hlen('hash:key')), 3, 'HLEN correct');

        # HEXISTS
        ok(await_f($r->hexists('hash:key', 'field1')), 'HEXISTS finds field');
        ok(!await_f($r->hexists('hash:key', 'nofield')), 'HEXISTS false for missing');

        # HDEL
        await_f($r->hdel('hash:key', 'f3'));
        ok(!await_f($r->hexists('hash:key', 'f3')), 'HDEL removes field');

        # HINCRBY
        await_f($r->hset('hash:num', 'count', '10'));
        is(await_f($r->hincrby('hash:num', 'count', 5)), 15, 'HINCRBY works');

        cleanup_keys($r, 'hash:*');
        $r->disconnect;
    };

    subtest 'sorted sets' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # ZADD
        await_f($r->zadd('zset:key', 1, 'one', 2, 'two', 3, 'three'));

        # ZCARD
        is(await_f($r->zcard('zset:key')), 3, 'ZCARD correct');

        # ZSCORE
        is(await_f($r->zscore('zset:key', 'two')), 2, 'ZSCORE correct');

        # ZRANK
        is(await_f($r->zrank('zset:key', 'one')), 0, 'ZRANK correct');
        is(await_f($r->zrank('zset:key', 'three')), 2, 'ZRANK for third');

        # ZRANGE
        my $range = await_f($r->zrange('zset:key', 0, -1));
        is($range, ['one', 'two', 'three'], 'ZRANGE works');

        # ZRANGEBYSCORE
        my $by_score = await_f($r->zrangebyscore('zset:key', 1, 2));
        is($by_score, ['one', 'two'], 'ZRANGEBYSCORE works');

        # ZINCRBY
        is(await_f($r->zincrby('zset:key', 10, 'one')), 11, 'ZINCRBY works');
        is(await_f($r->zrank('zset:key', 'one')), 2, 'ZINCRBY changes rank');

        # ZREM
        await_f($r->zrem('zset:key', 'two'));
        is(await_f($r->zcard('zset:key')), 2, 'ZREM removes member');

        cleanup_keys($r, 'zset:*');
        $r->disconnect;
    };

    subtest 'keys operations' => sub {
        my $r = Future::IO::Redis->new(
            host => $ENV{REDIS_HOST} // 'localhost',
        );
        await_f($r->connect);

        # Setup
        await_f($r->set('keys:a', '1'));
        await_f($r->set('keys:b', '2'));
        await_f($r->set('keys:c', '3'));

        # KEYS
        my $keys = await_f($r->keys('keys:*'));
        is([sort @$keys], ['keys:a', 'keys:b', 'keys:c'], 'KEYS pattern works');

        # EXISTS
        ok(await_f($r->exists('keys:a')), 'EXISTS finds key');
        ok(!await_f($r->exists('keys:nonexistent')), 'EXISTS false for missing');

        # TYPE
        is(await_f($r->type('keys:a')), 'string', 'TYPE works');

        # RENAME
        await_f($r->rename('keys:a', 'keys:renamed'));
        ok(await_f($r->exists('keys:renamed')), 'RENAME works');
        ok(!await_f($r->exists('keys:a')), 'old key gone after RENAME');

        # EXPIRE/TTL
        await_f($r->expire('keys:b', 100));
        my $ttl = await_f($r->ttl('keys:b'));
        ok($ttl > 0 && $ttl <= 100, 'EXPIRE/TTL work');

        # DEL
        await_f($r->del('keys:b', 'keys:c'));
        ok(!await_f($r->exists('keys:b')), 'DEL removes key');
        ok(!await_f($r->exists('keys:c')), 'DEL removes multiple');

        cleanup_keys($r, 'keys:*');
        $r->disconnect;
    };

    $redis->disconnect;
}

done_testing;
