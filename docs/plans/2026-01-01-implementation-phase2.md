# Async::Redis Phase 2: Command Generation

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Auto-generate Redis command methods from redis-doc, enabling idiomatic `$redis->get('key')` API instead of `$redis->command('GET', 'key')`, with automatic key prefixing support.

**Architecture:** Build script fetches commands.json from redis-doc, generates Commands.pm (role consumed by main class) and KeyExtractor.pm (key position logic for prefixing). Commands use snake_case naming, subcommands become `client_setname`, etc.

**Tech Stack:** Perl 5.18+, JSON::PP (core), HTTP::Tiny (core), Future::AsyncAwait

**Prerequisite:** Phase 1 complete (error classes, URI, timeouts, reconnection, auth, TLS)

---

## Task Overview

| Task | Focus | Files |
|------|-------|-------|
| 7 | Command Generation Script | `bin/generate-commands`, `share/commands.json` |
| 8 | Commands.pm + Tests | `lib/Future/IO/Redis/Commands.pm`, `t/20-commands/*.t` |
| 9 | KeyExtractor + Prefixing | `lib/Future/IO/Redis/KeyExtractor.pm`, `share/key_overrides.json` |

---

## Task 7: Command Generation Script

**Files:**
- Create: `bin/generate-commands`
- Create: `share/commands.json` (cached from redis-doc)
- Create: `t/01-unit/generate-commands.t`

### Step 1: Write the failing test

```perl
# t/01-unit/generate-commands.t
use Test2::V0;
use File::Temp qw(tempdir);
use File::Spec;

# Test that the generator produces valid output
subtest 'generator produces Commands.pm' => sub {
    my $tempdir = tempdir(CLEANUP => 1);
    my $output = File::Spec->catfile($tempdir, 'Commands.pm');

    # Run generator with our cached commands.json
    my $result = system($^X, 'bin/generate-commands',
        '--input', 'share/commands.json',
        '--output', $output,
    );

    is($result, 0, 'generator exits successfully');
    ok(-f $output, 'Commands.pm created');

    # Check content
    open my $fh, '<', $output or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/package Async::Redis::Commands/, 'package declaration');
    like($content, qr/use Future::AsyncAwait/, 'uses async/await');
    like($content, qr/async sub get\b/, 'has get method');
    like($content, qr/async sub set\b/, 'has set method');
    like($content, qr/async sub hgetall\b/, 'has hgetall method');
    like($content, qr/async sub client_setname\b/, 'has subcommand methods');
};

subtest 'generator handles missing input' => sub {
    my $result = system($^X, 'bin/generate-commands',
        '--input', '/nonexistent/file.json',
        '--output', '/dev/null',
    );

    isnt($result, 0, 'generator fails on missing input');
};

subtest 'naming conventions' => sub {
    my $tempdir = tempdir(CLEANUP => 1);
    my $output = File::Spec->catfile($tempdir, 'Commands.pm');

    system($^X, 'bin/generate-commands',
        '--input', 'share/commands.json',
        '--output', $output,
    );

    open my $fh, '<', $output or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;

    # Multi-word commands become snake_case
    like($content, qr/async sub client_getname\b/, 'CLIENT GETNAME -> client_getname');
    like($content, qr/async sub cluster_addslots\b/, 'CLUSTER ADDSLOTS -> cluster_addslots');
    like($content, qr/async sub config_get\b/, 'CONFIG GET -> config_get');

    # Hyphens become underscores
    like($content, qr/async sub client_no_evict\b/, 'CLIENT NO-EVICT -> client_no_evict');
};

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/01-unit/generate-commands.t`
Expected: FAIL with "No such file or directory" for bin/generate-commands

### Step 3: Fetch and cache commands.json

```bash
mkdir -p share
curl -L https://raw.githubusercontent.com/redis/redis-doc/master/commands.json \
     -o share/commands.json
```

### Step 4: Write the generator script

```perl
#!/usr/bin/env perl
# bin/generate-commands
#
# Generates Async::Redis::Commands from redis-doc commands.json

use strict;
use warnings;
use 5.018;
use Getopt::Long;
use JSON::PP;
use File::Basename;

my ($input, $output, $help);
GetOptions(
    'input=s'  => \$input,
    'output=s' => \$output,
    'help'     => \$help,
) or usage();
usage() if $help;

$input  //= 'share/commands.json';
$output //= 'lib/Future/IO/Redis/Commands.pm';

die "Input file not found: $input\n" unless -f $input;

# Load commands.json
open my $fh, '<', $input or die "Cannot open $input: $!";
my $json = do { local $/; <$fh> };
close $fh;

my $commands = decode_json($json);

# Generate module
my $code = generate_module($commands);

# Write output
my $dir = dirname($output);
system("mkdir", "-p", $dir) if $dir && !-d $dir;

open my $out, '>', $output or die "Cannot write $output: $!";
print $out $code;
close $out;

say "Generated $output with " . scalar(keys %$commands) . " commands";
exit 0;

sub usage {
    say "Usage: $0 [--input FILE] [--output FILE]";
    say "  --input   Path to commands.json (default: share/commands.json)";
    say "  --output  Output module path (default: lib/Future/IO/Redis/Commands.pm)";
    exit 1;
}

sub generate_module {
    my ($commands) = @_;

    my @methods;
    my %seen;

    for my $cmd (sort keys %$commands) {
        my $info = $commands->{$cmd};
        my $method = cmd_to_method($cmd);

        next if $seen{$method}++;

        my $parts = [split /\s+/, $cmd];
        my $is_subcommand = @$parts > 1;

        push @methods, generate_method($method, $parts, $info);
    }

    return <<"END_MODULE";
# lib/Future/IO/Redis/Commands.pm
# AUTO-GENERATED - DO NOT EDIT
# Generated from redis-doc commands.json
#
# This module provides async method wrappers for all Redis commands.
# Consume this role in Async::Redis.

package Async::Redis::Commands;

use strict;
use warnings;
use 5.018;

use Future::AsyncAwait;

@{[ join("\n\n", @methods) ]}

1;

__END__

=head1 NAME

Async::Redis::Commands - Auto-generated Redis command methods

=head1 DESCRIPTION

This module is auto-generated from the Redis command documentation.
It provides async method wrappers for all Redis commands.

Do not edit this file directly. Regenerate with:

  perl bin/generate-commands

=cut
END_MODULE
}

sub cmd_to_method {
    my ($cmd) = @_;

    # Replace spaces and hyphens with underscores, lowercase
    my $method = lc($cmd);
    $method =~ s/[\s-]+/_/g;

    return $method;
}

sub generate_method {
    my ($method, $parts, $info) = @_;

    my $cmd_name = uc($parts->[0]);
    my @subcmd = @$parts[1..$#$parts];

    # Check for special transformations
    if ($method eq 'hgetall') {
        return generate_hgetall();
    }
    elsif ($method eq 'info') {
        return generate_info();
    }
    elsif ($method eq 'time') {
        return generate_time();
    }

    # Standard command
    if (@subcmd) {
        my $subcmd_str = join(', ', map { "'$_'" } map { uc } @subcmd);
        return <<"END_METHOD";
async sub $method {
    my \$self = shift;
    return await \$self->command('$cmd_name', $subcmd_str, \@_);
}
END_METHOD
    }
    else {
        return <<"END_METHOD";
async sub $method {
    my \$self = shift;
    return await \$self->command('$cmd_name', \@_);
}
END_METHOD
    }
}

sub generate_hgetall {
    return <<'END_METHOD';
async sub hgetall {
    my $self = shift;
    my $arr = await $self->command('HGETALL', @_);
    return { @$arr };  # Convert array to hash
}
END_METHOD
}

sub generate_info {
    return <<'END_METHOD';
async sub info {
    my $self = shift;
    my $raw = await $self->command('INFO', @_);
    return _parse_info($raw);
}

sub _parse_info {
    my ($raw) = @_;
    return {} unless defined $raw;

    my %info;
    my $section = 'default';

    for my $line (split /\r?\n/, $raw) {
        if ($line =~ /^# (\w+)/) {
            $section = lc($1);
            $info{$section} //= {};
        }
        elsif ($line =~ /^(\w+):(.*)$/) {
            $info{$section}{$1} = $2;
        }
    }

    return \%info;
}
END_METHOD
}

sub generate_time {
    return <<'END_METHOD';
async sub time {
    my $self = shift;
    my $arr = await $self->command('TIME', @_);
    return {
        seconds      => $arr->[0],
        microseconds => $arr->[1],
    };
}
END_METHOD
}
```

### Step 5: Make generator executable

```bash
chmod +x bin/generate-commands
```

### Step 6: Run test to verify it passes

Run: `prove -l t/01-unit/generate-commands.t`
Expected: PASS

### Step 7: Generate the initial Commands.pm

```bash
perl bin/generate-commands
```

### Step 8: Commit

```bash
git add bin/generate-commands share/commands.json t/01-unit/generate-commands.t
git commit -m "$(cat <<'EOF'
feat: add command generation script

- bin/generate-commands parses redis-doc commands.json
- Generates async method for each Redis command
- snake_case naming: CLIENT SETNAME -> client_setname
- Special transformations for HGETALL, INFO, TIME
- Cached commands.json in share/

EOF
)"
```

---

## Task 8: Commands.pm and Command Category Tests

**Files:**
- Generate: `lib/Future/IO/Redis/Commands.pm`
- Create: `t/01-unit/commands.t`
- Create: `t/20-commands/strings.t`
- Create: `t/20-commands/hashes.t`
- Create: `t/20-commands/lists.t`
- Create: `t/20-commands/sets.t`
- Create: `t/20-commands/sorted-sets.t`
- Create: `t/20-commands/keys.t`
- Modify: `lib/Future/IO/Redis.pm` (consume Commands role)

### Step 1: Write unit test for Commands.pm

```perl
# t/01-unit/commands.t
use Test2::V0;
use Async::Redis::Commands;

subtest 'module loads' => sub {
    ok(Async::Redis::Commands->can('get'), 'has get method');
    ok(Async::Redis::Commands->can('set'), 'has set method');
    ok(Async::Redis::Commands->can('del'), 'has del method');
    ok(Async::Redis::Commands->can('exists'), 'has exists method');
};

subtest 'string commands exist' => sub {
    for my $cmd (qw(get set append getrange setrange strlen incr decr incrby decrby)) {
        ok(Async::Redis::Commands->can($cmd), "has $cmd method");
    }
};

subtest 'hash commands exist' => sub {
    for my $cmd (qw(hset hget hdel hexists hlen hkeys hvals hgetall hmset hmget hsetnx hincrby)) {
        ok(Async::Redis::Commands->can($cmd), "has $cmd method");
    }
};

subtest 'list commands exist' => sub {
    for my $cmd (qw(lpush rpush lpop rpop llen lrange lindex lset lrem linsert)) {
        ok(Async::Redis::Commands->can($cmd), "has $cmd method");
    }
};

subtest 'set commands exist' => sub {
    for my $cmd (qw(sadd srem smembers sismember scard sinter sunion sdiff spop srandmember)) {
        ok(Async::Redis::Commands->can($cmd), "has $cmd method");
    }
};

subtest 'sorted set commands exist' => sub {
    for my $cmd (qw(zadd zrem zscore zrank zrange zrangebyscore zcard zincrby)) {
        ok(Async::Redis::Commands->can($cmd), "has $cmd method");
    }
};

subtest 'subcommand methods exist' => sub {
    ok(Async::Redis::Commands->can('client_setname'), 'has client_setname');
    ok(Async::Redis::Commands->can('client_getname'), 'has client_getname');
    ok(Async::Redis::Commands->can('config_get'), 'has config_get');
    ok(Async::Redis::Commands->can('config_set'), 'has config_set');
};

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/01-unit/commands.t`
Expected: FAIL (Commands.pm not generated or incomplete)

### Step 3: Generate Commands.pm

```bash
perl bin/generate-commands --output lib/Future/IO/Redis/Commands.pm
```

### Step 4: Run unit test to verify it passes

Run: `prove -l t/01-unit/commands.t`
Expected: PASS

### Step 5: Integrate Commands into main Redis class

Edit `lib/Future/IO/Redis.pm` to consume the Commands role. Add after `use` statements:

```perl
# Import command methods
use Async::Redis::Commands;

# In the package, make methods available
# Option A: Inheritance
our @ISA = qw(Async::Redis::Commands);

# Option B: Or use Role::Tiny if you want role composition
# with 'Async::Redis::Commands';
```

### Step 6: Write string commands integration test

```perl
# t/20-commands/strings.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup test keys
    $loop->await($redis->del('test:str1', 'test:str2', 'test:counter'));

    subtest 'GET and SET' => sub {
        my $result = $loop->await($redis->set('test:str1', 'hello'));
        is($result, 'OK', 'SET returns OK');

        my $value = $loop->await($redis->get('test:str1'));
        is($value, 'hello', 'GET returns value');
    };

    subtest 'SET with options' => sub {
        my $result = $loop->await($redis->set('test:str2', 'world', 'EX', 60));
        is($result, 'OK', 'SET with EX returns OK');

        my $ttl = $loop->await($redis->ttl('test:str2'));
        ok($ttl > 0 && $ttl <= 60, 'TTL set correctly');
    };

    subtest 'INCR and DECR' => sub {
        $loop->await($redis->set('test:counter', '10'));

        my $result = $loop->await($redis->incr('test:counter'));
        is($result, 11, 'INCR returns new value');

        $result = $loop->await($redis->decr('test:counter'));
        is($result, 10, 'DECR returns new value');

        $result = $loop->await($redis->incrby('test:counter', 5));
        is($result, 15, 'INCRBY returns new value');
    };

    subtest 'APPEND and STRLEN' => sub {
        $loop->await($redis->set('test:str1', 'hello'));

        my $len = $loop->await($redis->append('test:str1', ' world'));
        is($len, 11, 'APPEND returns new length');

        my $value = $loop->await($redis->get('test:str1'));
        is($value, 'hello world', 'APPEND concatenated correctly');

        $len = $loop->await($redis->strlen('test:str1'));
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
            $loop->await($redis->set("test:nb:$i", "value$i"));
            $loop->await($redis->get("test:nb:$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 5, "Event loop ticked " . scalar(@ticks) . " times during 200 commands");

        # Cleanup
        $loop->await($redis->del(map { "test:nb:$_" } 1..100));
    };

    # Cleanup
    $loop->await($redis->del('test:str1', 'test:str2', 'test:counter'));
}

done_testing;
```

### Step 7: Run string commands test

Run: `prove -l t/20-commands/strings.t`
Expected: PASS (if Redis available) or SKIP

### Step 8: Write hash commands test

```perl
# t/20-commands/hashes.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('test:hash'));

    subtest 'HSET and HGET' => sub {
        my $result = $loop->await($redis->hset('test:hash', 'field1', 'value1'));
        ok($result >= 0, 'HSET returns count');

        my $value = $loop->await($redis->hget('test:hash', 'field1'));
        is($value, 'value1', 'HGET returns value');
    };

    subtest 'HMSET and HMGET' => sub {
        $loop->await($redis->hmset('test:hash',
            'a', '1',
            'b', '2',
            'c', '3',
        ));

        my $values = $loop->await($redis->hmget('test:hash', 'a', 'b', 'c'));
        is($values, ['1', '2', '3'], 'HMGET returns values in order');
    };

    subtest 'HGETALL returns hash' => sub {
        my $hash = $loop->await($redis->hgetall('test:hash'));
        is(ref $hash, 'HASH', 'HGETALL returns hashref');
        is($hash->{field1}, 'value1', 'contains field1');
        is($hash->{a}, '1', 'contains a');
    };

    subtest 'HEXISTS and HDEL' => sub {
        my $exists = $loop->await($redis->hexists('test:hash', 'field1'));
        is($exists, 1, 'HEXISTS returns 1 for existing field');

        my $deleted = $loop->await($redis->hdel('test:hash', 'field1'));
        is($deleted, 1, 'HDEL returns count');

        $exists = $loop->await($redis->hexists('test:hash', 'field1'));
        is($exists, 0, 'HEXISTS returns 0 after delete');
    };

    subtest 'HKEYS, HVALS, HLEN' => sub {
        my $keys = $loop->await($redis->hkeys('test:hash'));
        ok(@$keys >= 3, 'HKEYS returns keys');

        my $vals = $loop->await($redis->hvals('test:hash'));
        ok(@$vals >= 3, 'HVALS returns values');

        my $len = $loop->await($redis->hlen('test:hash'));
        ok($len >= 3, 'HLEN returns count');
    };

    subtest 'HINCRBY' => sub {
        $loop->await($redis->hset('test:hash', 'counter', '10'));

        my $result = $loop->await($redis->hincrby('test:hash', 'counter', 5));
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
            $loop->await($redis->hset('test:hash', "field$i", "val$i"));
            $loop->await($redis->hget('test:hash', "field$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 3, "Event loop ticked during hash operations");
    };

    # Cleanup
    $loop->await($redis->del('test:hash'));
}

done_testing;
```

### Step 9: Write list commands test

```perl
# t/20-commands/lists.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('test:list'));

    subtest 'LPUSH and RPUSH' => sub {
        my $len = $loop->await($redis->rpush('test:list', 'a', 'b', 'c'));
        is($len, 3, 'RPUSH returns new length');

        $len = $loop->await($redis->lpush('test:list', 'z'));
        is($len, 4, 'LPUSH returns new length');
    };

    subtest 'LRANGE' => sub {
        my $list = $loop->await($redis->lrange('test:list', 0, -1));
        is($list, ['z', 'a', 'b', 'c'], 'LRANGE returns full list');

        $list = $loop->await($redis->lrange('test:list', 0, 1));
        is($list, ['z', 'a'], 'LRANGE with slice');
    };

    subtest 'LPOP and RPOP' => sub {
        my $val = $loop->await($redis->lpop('test:list'));
        is($val, 'z', 'LPOP returns left element');

        $val = $loop->await($redis->rpop('test:list'));
        is($val, 'c', 'RPOP returns right element');
    };

    subtest 'LLEN and LINDEX' => sub {
        my $len = $loop->await($redis->llen('test:list'));
        is($len, 2, 'LLEN returns length');

        my $val = $loop->await($redis->lindex('test:list', 0));
        is($val, 'a', 'LINDEX returns element at index');
    };

    subtest 'LSET' => sub {
        $loop->await($redis->lset('test:list', 0, 'A'));
        my $val = $loop->await($redis->lindex('test:list', 0));
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
            $loop->await($redis->rpush('test:list', "item$i"));
        }
        $loop->await($redis->lrange('test:list', 0, -1));

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 2, "Event loop ticked during list operations");
    };

    # Cleanup
    $loop->await($redis->del('test:list'));
}

done_testing;
```

### Step 10: Write set commands test

```perl
# t/20-commands/sets.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('test:set1', 'test:set2'));

    subtest 'SADD and SMEMBERS' => sub {
        my $added = $loop->await($redis->sadd('test:set1', 'a', 'b', 'c'));
        is($added, 3, 'SADD returns count');

        my $members = $loop->await($redis->smembers('test:set1'));
        is([sort @$members], ['a', 'b', 'c'], 'SMEMBERS returns all members');
    };

    subtest 'SISMEMBER and SCARD' => sub {
        my $is = $loop->await($redis->sismember('test:set1', 'a'));
        is($is, 1, 'SISMEMBER returns 1 for member');

        $is = $loop->await($redis->sismember('test:set1', 'z'));
        is($is, 0, 'SISMEMBER returns 0 for non-member');

        my $card = $loop->await($redis->scard('test:set1'));
        is($card, 3, 'SCARD returns cardinality');
    };

    subtest 'SREM' => sub {
        my $removed = $loop->await($redis->srem('test:set1', 'a'));
        is($removed, 1, 'SREM returns count');

        my $card = $loop->await($redis->scard('test:set1'));
        is($card, 2, 'cardinality decreased');
    };

    subtest 'SINTER, SUNION, SDIFF' => sub {
        $loop->await($redis->sadd('test:set1', 'a', 'b', 'c'));
        $loop->await($redis->sadd('test:set2', 'b', 'c', 'd'));

        my $inter = $loop->await($redis->sinter('test:set1', 'test:set2'));
        is([sort @$inter], ['b', 'c'], 'SINTER works');

        my $union = $loop->await($redis->sunion('test:set1', 'test:set2'));
        is([sort @$union], ['a', 'b', 'c', 'd'], 'SUNION works');

        my $diff = $loop->await($redis->sdiff('test:set1', 'test:set2'));
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
            $loop->await($redis->sadd('test:set1', "member$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 2, "Event loop ticked during set operations");
    };

    # Cleanup
    $loop->await($redis->del('test:set1', 'test:set2'));
}

done_testing;
```

### Step 11: Write sorted set commands test

```perl
# t/20-commands/sorted-sets.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('test:zset'));

    subtest 'ZADD and ZSCORE' => sub {
        my $added = $loop->await($redis->zadd('test:zset', 1, 'one', 2, 'two', 3, 'three'));
        is($added, 3, 'ZADD returns count');

        my $score = $loop->await($redis->zscore('test:zset', 'two'));
        is($score, '2', 'ZSCORE returns score');
    };

    subtest 'ZRANGE' => sub {
        my $range = $loop->await($redis->zrange('test:zset', 0, -1));
        is($range, ['one', 'two', 'three'], 'ZRANGE returns ordered members');

        # With WITHSCORES
        $range = $loop->await($redis->zrange('test:zset', 0, -1, 'WITHSCORES'));
        is($range, ['one', '1', 'two', '2', 'three', '3'], 'ZRANGE WITHSCORES works');
    };

    subtest 'ZRANK' => sub {
        my $rank = $loop->await($redis->zrank('test:zset', 'one'));
        is($rank, 0, 'ZRANK returns 0-based rank');

        $rank = $loop->await($redis->zrank('test:zset', 'three'));
        is($rank, 2, 'ZRANK for third element');
    };

    subtest 'ZINCRBY' => sub {
        my $new = $loop->await($redis->zincrby('test:zset', 10, 'one'));
        is($new, '11', 'ZINCRBY returns new score');

        # Now 'one' should be last
        my $range = $loop->await($redis->zrange('test:zset', -1, -1));
        is($range, ['one'], 'order updated after ZINCRBY');
    };

    subtest 'ZCARD and ZREM' => sub {
        my $card = $loop->await($redis->zcard('test:zset'));
        is($card, 3, 'ZCARD returns count');

        my $removed = $loop->await($redis->zrem('test:zset', 'one'));
        is($removed, 1, 'ZREM returns count');

        $card = $loop->await($redis->zcard('test:zset'));
        is($card, 2, 'count decreased after ZREM');
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
            $loop->await($redis->zadd('test:zset', $i, "member$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 2, "Event loop ticked during sorted set operations");
    };

    # Cleanup
    $loop->await($redis->del('test:zset'));
}

done_testing;
```

### Step 12: Write key commands test

```perl
# t/20-commands/keys.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    # Cleanup
    $loop->await($redis->del('test:key1', 'test:key2', 'test:key3'));

    subtest 'EXISTS' => sub {
        $loop->await($redis->set('test:key1', 'value'));

        my $exists = $loop->await($redis->exists('test:key1'));
        is($exists, 1, 'EXISTS returns 1 for existing key');

        $exists = $loop->await($redis->exists('test:nonexistent'));
        is($exists, 0, 'EXISTS returns 0 for non-existing key');

        # Multiple keys
        $loop->await($redis->set('test:key2', 'value2'));
        $exists = $loop->await($redis->exists('test:key1', 'test:key2', 'test:nonexistent'));
        is($exists, 2, 'EXISTS with multiple keys returns count');
    };

    subtest 'DEL' => sub {
        $loop->await($redis->set('test:key3', 'value3'));

        my $deleted = $loop->await($redis->del('test:key1', 'test:key2', 'test:key3'));
        is($deleted, 3, 'DEL returns count of deleted keys');

        my $exists = $loop->await($redis->exists('test:key1'));
        is($exists, 0, 'key deleted');
    };

    subtest 'EXPIRE and TTL' => sub {
        $loop->await($redis->set('test:key1', 'value'));
        $loop->await($redis->expire('test:key1', 60));

        my $ttl = $loop->await($redis->ttl('test:key1'));
        ok($ttl > 0 && $ttl <= 60, "TTL is $ttl (expected 1-60)");

        # Remove expiry
        $loop->await($redis->persist('test:key1'));
        $ttl = $loop->await($redis->ttl('test:key1'));
        is($ttl, -1, 'TTL is -1 after PERSIST');
    };

    subtest 'TYPE' => sub {
        $loop->await($redis->set('test:key1', 'string'));
        my $type = $loop->await($redis->type('test:key1'));
        is($type, 'string', 'TYPE returns string');

        $loop->await($redis->rpush('test:key2', 'item'));
        $type = $loop->await($redis->type('test:key2'));
        is($type, 'list', 'TYPE returns list');
    };

    subtest 'RENAME' => sub {
        $loop->await($redis->set('test:key1', 'value'));
        $loop->await($redis->rename('test:key1', 'test:key1:renamed'));

        my $exists = $loop->await($redis->exists('test:key1'));
        is($exists, 0, 'old key gone');

        $exists = $loop->await($redis->exists('test:key1:renamed'));
        is($exists, 1, 'new key exists');

        # Cleanup
        $loop->await($redis->del('test:key1:renamed'));
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
            $loop->await($redis->set("test:nb:$i", "value$i"));
            $loop->await($redis->exists("test:nb:$i"));
            $loop->await($redis->del("test:nb:$i"));
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 5, "Event loop ticked during key operations");
    };

    # Cleanup
    $loop->await($redis->del('test:key1', 'test:key2', 'test:key3'));
}

done_testing;
```

### Step 13: Run all command tests

Run: `prove -l t/20-commands/`
Expected: PASS (or SKIP if Redis not available)

### Step 14: Run all tests including non-blocking proof

Run: `prove -l t/`
Expected: PASS

### Step 15: Commit

```bash
git add lib/Future/IO/Redis/Commands.pm t/01-unit/commands.t t/20-commands/
git commit -m "$(cat <<'EOF'
feat: add auto-generated command methods and tests

Commands.pm:
- Auto-generated from redis-doc commands.json
- All standard Redis commands as async methods
- Subcommands: client_setname, config_get, etc.
- Special transformations: HGETALL -> hash, INFO -> parsed

Integration tests:
- t/20-commands/strings.t: GET, SET, INCR, APPEND, etc.
- t/20-commands/hashes.t: HSET, HGET, HGETALL, etc.
- t/20-commands/lists.t: LPUSH, RPOP, LRANGE, etc.
- t/20-commands/sets.t: SADD, SMEMBERS, SINTER, etc.
- t/20-commands/sorted-sets.t: ZADD, ZRANGE, ZSCORE, etc.
- t/20-commands/keys.t: DEL, EXISTS, EXPIRE, TTL, etc.

All tests include non-blocking verification.

EOF
)"
```

---

## Task 9: KeyExtractor and Key Prefixing

**Files:**
- Create: `lib/Future/IO/Redis/KeyExtractor.pm`
- Create: `share/key_overrides.json`
- Create: `t/01-unit/key-extractor.t`
- Create: `t/20-commands/prefix.t`
- Modify: `lib/Future/IO/Redis.pm` (add prefix option and use KeyExtractor)
- Modify: `bin/generate-commands` (generate key position metadata)

### Step 1: Write unit test for KeyExtractor

```perl
# t/01-unit/key-extractor.t
use Test2::V0;
use Async::Redis::KeyExtractor;

subtest 'simple single-key commands' => sub {
    my @indices = Async::Redis::KeyExtractor::extract_key_indices('GET', 'mykey');
    is(\@indices, [0], 'GET: key at index 0');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('SET', 'mykey', 'value');
    is(\@indices, [0], 'SET: key at index 0');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('DEL', 'key1');
    is(\@indices, [0], 'DEL single: key at index 0');
};

subtest 'multi-key commands' => sub {
    my @indices = Async::Redis::KeyExtractor::extract_key_indices('MGET', 'k1', 'k2', 'k3');
    is(\@indices, [0, 1, 2], 'MGET: all args are keys');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('DEL', 'k1', 'k2', 'k3');
    is(\@indices, [0, 1, 2], 'DEL multi: all args are keys');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('EXISTS', 'k1', 'k2');
    is(\@indices, [0, 1], 'EXISTS: all args are keys');
};

subtest 'MSET - even indices only' => sub {
    my @indices = Async::Redis::KeyExtractor::extract_key_indices('MSET', 'k1', 'v1', 'k2', 'v2');
    is(\@indices, [0, 2], 'MSET: only even indices are keys');
};

subtest 'hash commands - first arg is key' => sub {
    my @indices = Async::Redis::KeyExtractor::extract_key_indices('HSET', 'hash', 'field', 'value');
    is(\@indices, [0], 'HSET: first arg is key');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('HGET', 'hash', 'field');
    is(\@indices, [0], 'HGET: first arg is key');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('HGETALL', 'hash');
    is(\@indices, [0], 'HGETALL: first arg is key');
};

subtest 'list commands - first arg is key' => sub {
    my @indices = Async::Redis::KeyExtractor::extract_key_indices('LPUSH', 'list', 'item1', 'item2');
    is(\@indices, [0], 'LPUSH: first arg is key');

    @indices = Async::Redis::KeyExtractor::extract_key_indices('LRANGE', 'list', 0, -1);
    is(\@indices, [0], 'LRANGE: first arg is key');
};

subtest 'EVAL/EVALSHA - dynamic numkeys' => sub {
    # EVAL script numkeys key1 key2 arg1 arg2
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'EVAL', 'return 1', 2, 'key1', 'key2', 'arg1', 'arg2'
    );
    is(\@indices, [2, 3], 'EVAL: keys at indices 2,3 (numkeys=2)');

    @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'EVALSHA', 'abc123', 1, 'mykey', 'arg1'
    );
    is(\@indices, [2], 'EVALSHA: key at index 2 (numkeys=1)');

    @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'EVAL', 'return 1', 0, 'arg1', 'arg2'
    );
    is(\@indices, [], 'EVAL with numkeys=0: no keys');
};

subtest 'BITOP - skip operation arg' => sub {
    # BITOP operation destkey srckey1 [srckey2 ...]
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'BITOP', 'AND', 'dest', 'src1', 'src2'
    );
    is(\@indices, [1, 2, 3], 'BITOP: keys start at index 1');
};

subtest 'OBJECT subcommands' => sub {
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'OBJECT', 'ENCODING', 'mykey'
    );
    is(\@indices, [1], 'OBJECT ENCODING: key at index 1');
};

subtest 'XREAD - keys between STREAMS and IDs' => sub {
    # XREAD [COUNT n] [BLOCK ms] STREAMS stream1 stream2 id1 id2
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'XREAD', 'STREAMS', 's1', 's2', '0', '0'
    );
    is(\@indices, [1, 2], 'XREAD: streams at indices 1,2');

    @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'XREAD', 'COUNT', '10', 'BLOCK', '1000', 'STREAMS', 's1', 's2', 's3', '0', '0', '0'
    );
    is(\@indices, [6, 7, 8], 'XREAD with options: streams after STREAMS keyword');
};

subtest 'MIGRATE - single key or KEYS keyword' => sub {
    # MIGRATE host port key db timeout [COPY] [REPLACE] [AUTH pw] [KEYS k1 k2]
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'MIGRATE', 'host', '6379', 'mykey', '0', '5000'
    );
    is(\@indices, [2], 'MIGRATE single: key at index 2');

    @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'MIGRATE', 'host', '6379', '', '0', '5000', 'KEYS', 'k1', 'k2'
    );
    is(\@indices, [6, 7], 'MIGRATE multi: keys after KEYS keyword');
};

subtest 'apply_prefix' => sub {
    my @args = Async::Redis::KeyExtractor::apply_prefix(
        'myapp:', 'GET', 'key1'
    );
    is(\@args, ['myapp:key1'], 'GET with prefix');

    @args = Async::Redis::KeyExtractor::apply_prefix(
        'myapp:', 'SET', 'key1', 'value'
    );
    is(\@args, ['myapp:key1', 'value'], 'SET: value not prefixed');

    @args = Async::Redis::KeyExtractor::apply_prefix(
        'myapp:', 'MGET', 'k1', 'k2', 'k3'
    );
    is(\@args, ['myapp:k1', 'myapp:k2', 'myapp:k3'], 'MGET: all keys prefixed');

    @args = Async::Redis::KeyExtractor::apply_prefix(
        'myapp:', 'MSET', 'k1', 'v1', 'k2', 'v2'
    );
    is(\@args, ['myapp:k1', 'v1', 'myapp:k2', 'v2'], 'MSET: only keys prefixed');
};

subtest 'no prefix when empty' => sub {
    my @args = Async::Redis::KeyExtractor::apply_prefix(
        '', 'GET', 'key1'
    );
    is(\@args, ['key1'], 'empty prefix: unchanged');

    @args = Async::Redis::KeyExtractor::apply_prefix(
        undef, 'GET', 'key1'
    );
    is(\@args, ['key1'], 'undef prefix: unchanged');
};

subtest 'unknown command - no prefix, warn in debug' => sub {
    local $ENV{REDIS_DEBUG} = 0;  # Suppress warning
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'UNKNOWNCMD', 'arg1', 'arg2'
    );
    is(\@indices, [], 'unknown command: no indices returned');
};

done_testing;
```

### Step 2: Run test to verify it fails

Run: `prove -l t/01-unit/key-extractor.t`
Expected: FAIL with "Can't locate Future/IO/Redis/KeyExtractor.pm"

### Step 3: Create key_overrides.json

```json
{
    "BITOP": {
        "note": "First arg is operation, rest are keys (destkey + srckeys)",
        "keys": { "type": "range", "start": 1, "end": -1 }
    },
    "OBJECT": {
        "note": "Subcommand first, then key",
        "subcommands": {
            "ENCODING": { "keys": [1] },
            "FREQ": { "keys": [1] },
            "IDLETIME": { "keys": [1] },
            "REFCOUNT": { "keys": [1] },
            "HELP": { "keys": [] }
        }
    },
    "DEBUG": {
        "note": "DEBUG commands are dangerous, no prefixing",
        "keys": "none"
    },
    "MIGRATE": {
        "note": "key at position 2, or after KEYS keyword for multi-key",
        "keys": { "type": "custom", "handler": "_keys_for_migrate" }
    },
    "XREAD": {
        "note": "Keys are streams between STREAMS keyword and IDs",
        "keys": { "type": "custom", "handler": "_keys_for_xread" }
    },
    "XREADGROUP": {
        "note": "Similar to XREAD",
        "keys": { "type": "custom", "handler": "_keys_for_xread" }
    },
    "SORT": {
        "note": "First arg is key, BY/GET patterns need separate handling",
        "keys": [0]
    },
    "GEORADIUS": {
        "note": "First arg is key, STORE/STOREDIST args are also keys",
        "keys": { "type": "custom", "handler": "_keys_for_georadius" }
    },
    "GEORADIUSBYMEMBER": {
        "note": "Same as GEORADIUS",
        "keys": { "type": "custom", "handler": "_keys_for_georadius" }
    }
}
```

Save to: `share/key_overrides.json`

### Step 4: Write KeyExtractor.pm

```perl
# lib/Future/IO/Redis/KeyExtractor.pm
package Async::Redis::KeyExtractor;

use strict;
use warnings;
use 5.018;

# Key position handlers for each command
# Generated from commands.json key_specs + manual overrides
our %KEY_POSITIONS = (
    # Simple single-key commands (first arg is key)
    'GET'       => sub { (0) },
    'SET'       => sub { (0) },
    'GETEX'     => sub { (0) },
    'GETDEL'    => sub { (0) },
    'GETSET'    => sub { (0) },
    'APPEND'    => sub { (0) },
    'STRLEN'    => sub { (0) },
    'SETEX'     => sub { (0) },
    'PSETEX'    => sub { (0) },
    'SETNX'     => sub { (0) },
    'SETRANGE'  => sub { (0) },
    'GETRANGE'  => sub { (0) },
    'INCR'      => sub { (0) },
    'DECR'      => sub { (0) },
    'INCRBY'    => sub { (0) },
    'DECRBY'    => sub { (0) },
    'INCRBYFLOAT' => sub { (0) },

    # Multi-key commands (all args are keys)
    'MGET'      => sub { (0 .. $#_) },
    'DEL'       => sub { (0 .. $#_) },
    'UNLINK'    => sub { (0 .. $#_) },
    'EXISTS'    => sub { (0 .. $#_) },
    'TOUCH'     => sub { (0 .. $#_) },
    'WATCH'     => sub { (0 .. $#_) },

    # MSET: even indices are keys
    'MSET'      => sub { grep { $_ % 2 == 0 } (0 .. $#_) },
    'MSETNX'    => sub { grep { $_ % 2 == 0 } (0 .. $#_) },

    # Hash commands (first arg is key)
    'HSET'      => sub { (0) },
    'HGET'      => sub { (0) },
    'HDEL'      => sub { (0) },
    'HEXISTS'   => sub { (0) },
    'HLEN'      => sub { (0) },
    'HKEYS'     => sub { (0) },
    'HVALS'     => sub { (0) },
    'HGETALL'   => sub { (0) },
    'HMSET'     => sub { (0) },
    'HMGET'     => sub { (0) },
    'HSETNX'    => sub { (0) },
    'HINCRBY'   => sub { (0) },
    'HINCRBYFLOAT' => sub { (0) },
    'HSCAN'     => sub { (0) },
    'HRANDFIELD' => sub { (0) },

    # List commands (first arg is key)
    'LPUSH'     => sub { (0) },
    'RPUSH'     => sub { (0) },
    'LPOP'      => sub { (0) },
    'RPOP'      => sub { (0) },
    'LLEN'      => sub { (0) },
    'LRANGE'    => sub { (0) },
    'LINDEX'    => sub { (0) },
    'LSET'      => sub { (0) },
    'LREM'      => sub { (0) },
    'LINSERT'   => sub { (0) },
    'LTRIM'     => sub { (0) },
    'LPOS'      => sub { (0) },
    'LPUSHX'    => sub { (0) },
    'RPUSHX'    => sub { (0) },

    # Blocking list commands (first arg is key, or multiple keys)
    'BLPOP'     => \&_keys_for_blocking_list,
    'BRPOP'     => \&_keys_for_blocking_list,
    'BLMOVE'    => sub { (0, 1) },  # source and dest
    'BRPOPLPUSH' => sub { (0, 1) },
    'LMOVE'     => sub { (0, 1) },

    # Set commands (first arg is key)
    'SADD'      => sub { (0) },
    'SREM'      => sub { (0) },
    'SMEMBERS'  => sub { (0) },
    'SISMEMBER' => sub { (0) },
    'SMISMEMBER' => sub { (0) },
    'SCARD'     => sub { (0) },
    'SPOP'      => sub { (0) },
    'SRANDMEMBER' => sub { (0) },
    'SSCAN'     => sub { (0) },
    'SMOVE'     => sub { (0, 1) },  # source and dest
    'SINTER'    => sub { (0 .. $#_) },
    'SUNION'    => sub { (0 .. $#_) },
    'SDIFF'     => sub { (0 .. $#_) },
    'SINTERSTORE' => sub { (0 .. $#_) },
    'SUNIONSTORE' => sub { (0 .. $#_) },
    'SDIFFSTORE' => sub { (0 .. $#_) },
    'SINTERCARD' => \&_keys_for_sintercard,

    # Sorted set commands (first arg is key)
    'ZADD'      => sub { (0) },
    'ZREM'      => sub { (0) },
    'ZSCORE'    => sub { (0) },
    'ZRANK'     => sub { (0) },
    'ZREVRANK'  => sub { (0) },
    'ZRANGE'    => sub { (0) },
    'ZREVRANGE' => sub { (0) },
    'ZRANGEBYSCORE' => sub { (0) },
    'ZREVRANGEBYSCORE' => sub { (0) },
    'ZCARD'     => sub { (0) },
    'ZCOUNT'    => sub { (0) },
    'ZINCRBY'   => sub { (0) },
    'ZLEXCOUNT' => sub { (0) },
    'ZRANGEBYLEX' => sub { (0) },
    'ZREVRANGEBYLEX' => sub { (0) },
    'ZPOPMIN'   => sub { (0) },
    'ZPOPMAX'   => sub { (0) },
    'BZPOPMIN'  => \&_keys_for_blocking_list,
    'BZPOPMAX'  => \&_keys_for_blocking_list,
    'ZRANGESTORE' => sub { (0, 1) },
    'ZINTER'    => \&_keys_for_zinter,
    'ZUNION'    => \&_keys_for_zinter,
    'ZDIFF'     => \&_keys_for_zinter,
    'ZINTERSTORE' => \&_keys_for_zinterstore,
    'ZUNIONSTORE' => \&_keys_for_zinterstore,
    'ZDIFFSTORE' => \&_keys_for_zinterstore,
    'ZSCAN'     => sub { (0) },
    'ZRANDMEMBER' => sub { (0) },
    'ZMPOP'     => \&_keys_for_zmpop,
    'BZMPOP'    => \&_keys_for_bzmpop,

    # Key commands
    'EXPIRE'    => sub { (0) },
    'EXPIREAT'  => sub { (0) },
    'PEXPIRE'   => sub { (0) },
    'PEXPIREAT' => sub { (0) },
    'TTL'       => sub { (0) },
    'PTTL'      => sub { (0) },
    'PERSIST'   => sub { (0) },
    'TYPE'      => sub { (0) },
    'RENAME'    => sub { (0, 1) },
    'RENAMENX'  => sub { (0, 1) },
    'COPY'      => sub { (0, 1) },
    'DUMP'      => sub { (0) },
    'RESTORE'   => sub { (0) },
    'EXPIRETIME' => sub { (0) },
    'PEXPIRETIME' => sub { (0) },
    'OBJECT'    => \&_keys_for_object,

    # EVAL/EVALSHA - dynamic based on numkeys
    'EVAL'      => \&_keys_for_eval,
    'EVALSHA'   => \&_keys_for_eval,
    'EVALSHA_RO' => \&_keys_for_eval,
    'EVAL_RO'   => \&_keys_for_eval,
    'FCALL'     => \&_keys_for_eval,
    'FCALL_RO'  => \&_keys_for_eval,

    # BITOP - skip operation arg
    'BITOP'     => sub { (1 .. $#_) },

    # Stream commands
    'XADD'      => sub { (0) },
    'XLEN'      => sub { (0) },
    'XRANGE'    => sub { (0) },
    'XREVRANGE' => sub { (0) },
    'XREAD'     => \&_keys_for_xread,
    'XREADGROUP' => \&_keys_for_xread,
    'XINFO'     => \&_keys_for_xinfo,
    'XGROUP'    => \&_keys_for_xgroup,
    'XACK'      => sub { (0) },
    'XCLAIM'    => sub { (0) },
    'XAUTOCLAIM' => sub { (0) },
    'XPENDING'  => sub { (0) },
    'XTRIM'     => sub { (0) },
    'XDEL'      => sub { (0) },
    'XSETID'    => sub { (0) },

    # Geo commands
    'GEOADD'    => sub { (0) },
    'GEOPOS'    => sub { (0) },
    'GEODIST'   => sub { (0) },
    'GEOHASH'   => sub { (0) },
    'GEORADIUS' => \&_keys_for_georadius,
    'GEORADIUSBYMEMBER' => \&_keys_for_georadius,
    'GEOSEARCH' => sub { (0) },
    'GEOSEARCHSTORE' => sub { (0, 1) },

    # MIGRATE - special handling
    'MIGRATE'   => \&_keys_for_migrate,

    # SORT
    'SORT'      => sub { (0) },
    'SORT_RO'   => sub { (0) },

    # SCAN commands return patterns, not keys - first arg is key for HSCAN/SSCAN/ZSCAN
    'SCAN'      => sub { () },  # No key, cursor-based

    # Pub/Sub - channels, not keys
    'PUBLISH'   => sub { () },
    'SUBSCRIBE' => sub { () },
    'UNSUBSCRIBE' => sub { () },
    'PSUBSCRIBE' => sub { () },
    'PUNSUBSCRIBE' => sub { () },

    # Server commands - no keys
    'PING'      => sub { () },
    'ECHO'      => sub { () },
    'AUTH'      => sub { () },
    'SELECT'    => sub { () },
    'INFO'      => sub { () },
    'DBSIZE'    => sub { () },
    'FLUSHDB'   => sub { () },
    'FLUSHALL'  => sub { () },
    'SAVE'      => sub { () },
    'BGSAVE'    => sub { () },
    'LASTSAVE'  => sub { () },
    'TIME'      => sub { () },
    'CONFIG'    => sub { () },
    'CLIENT'    => sub { () },
    'SLOWLOG'   => sub { () },
    'DEBUG'     => sub { () },
    'MEMORY'    => sub { () },
    'MODULE'    => sub { () },
    'ACL'       => sub { () },
    'COMMAND'   => sub { () },
    'MULTI'     => sub { () },
    'EXEC'      => sub { () },
    'DISCARD'   => sub { () },
    'UNWATCH'   => sub { () },
    'SCRIPT'    => sub { () },
    'CLUSTER'   => sub { () },
    'READONLY'  => sub { () },
    'READWRITE' => sub { () },
    'WAIT'      => sub { () },
    'KEYS'      => sub { () },  # Pattern, not literal key
    'RANDOMKEY' => sub { () },
);

# Fallback patterns for unknown commands
our @FALLBACK_PATTERNS = (
    # Hash commands: first arg is key
    [ qr/^H(?:SET|GET|DEL|EXISTS|INCR|LEN|KEYS|VALS|GETALL|SCAN|MGET|MSET)/i, sub { (0) } ],

    # List commands: first arg is key
    [ qr/^[LR](?:PUSH|POP|LEN|INDEX|RANGE|SET|TRIM|REM|INSERT|POS)/i, sub { (0) } ],

    # Set commands: first arg is key
    [ qr/^S(?:ADD|REM|MEMBERS|ISMEMBER|CARD|POP|RANDMEMBER|SCAN)/i, sub { (0) } ],

    # Sorted set commands: first arg is key
    [ qr/^Z(?:ADD|REM|SCORE|RANK|RANGE|CARD|COUNT|INCRBY|SCAN)/i, sub { (0) } ],

    # Generic fallback: assume first arg is key for unknown X* commands (streams)
    [ qr/^X/i, sub { (0) } ],
);

sub extract_key_indices {
    my ($command, @args) = @_;
    $command = uc($command);

    # Check explicit handlers
    if (my $handler = $KEY_POSITIONS{$command}) {
        return $handler->(@args);
    }

    # Try fallback patterns
    for my $pattern (@FALLBACK_PATTERNS) {
        if ($command =~ $pattern->[0]) {
            return $pattern->[1]->(@args);
        }
    }

    # Unknown command - no prefixing, warn in debug mode
    warn "Unknown command '$command': key prefixing skipped" if $ENV{REDIS_DEBUG};
    return ();
}

sub apply_prefix {
    my ($prefix, $command, @args) = @_;
    return @args unless defined $prefix && $prefix ne '';

    my @key_indices = extract_key_indices($command, @args);
    for my $i (@key_indices) {
        next if $i > $#args;  # Safety check
        $args[$i] = $prefix . $args[$i];
    }

    return @args;
}

# --- Custom handlers for complex commands ---

sub _keys_for_eval {
    my (@args) = @_;
    # EVAL script numkeys [key ...] [arg ...]
    # EVALSHA sha1 numkeys [key ...] [arg ...]
    return () unless @args >= 2;

    my $numkeys = $args[1];
    return () unless defined $numkeys && $numkeys =~ /^\d+$/ && $numkeys > 0;

    # Keys are at indices 2 through 2+numkeys-1
    return (2 .. 2 + $numkeys - 1);
}

sub _keys_for_xread {
    my (@args) = @_;

    # Find STREAMS keyword
    my $streams_idx;
    for my $i (0 .. $#args) {
        if (uc($args[$i]) eq 'STREAMS') {
            $streams_idx = $i;
            last;
        }
    }
    return () unless defined $streams_idx;

    # Keys are between STREAMS and the IDs
    # Number of streams = number of IDs = (remaining args after STREAMS) / 2
    my $remaining = $#args - $streams_idx;
    my $num_streams = int($remaining / 2);

    return () unless $num_streams > 0;
    return ($streams_idx + 1 .. $streams_idx + $num_streams);
}

sub _keys_for_migrate {
    my (@args) = @_;
    my @key_indices;

    # MIGRATE host port key|"" db timeout [COPY] [REPLACE] [AUTH pw] [KEYS k1 k2 ...]

    # Single key at position 2 (unless empty string for multi-key)
    if (@args > 2 && $args[2] ne '') {
        push @key_indices, 2;
    }

    # Multi-key after KEYS keyword
    for my $i (0 .. $#args) {
        if (uc($args[$i]) eq 'KEYS') {
            push @key_indices, ($i + 1 .. $#args);
            last;
        }
    }

    return @key_indices;
}

sub _keys_for_object {
    my (@args) = @_;
    # OBJECT subcommand [key] [...]
    return () unless @args >= 2;

    my $subcmd = uc($args[0]);
    # Most OBJECT subcommands take key as second arg
    if ($subcmd =~ /^(ENCODING|FREQ|IDLETIME|REFCOUNT)$/) {
        return (1);
    }
    return ();
}

sub _keys_for_blocking_list {
    my (@args) = @_;
    # BLPOP key [key ...] timeout
    # Last arg is timeout, rest are keys
    return () unless @args >= 2;
    return (0 .. $#args - 1);
}

sub _keys_for_zinter {
    my (@args) = @_;
    # ZINTER numkeys key [key ...] [WEIGHTS ...] [AGGREGATE ...]
    return () unless @args >= 1;
    my $numkeys = $args[0];
    return () unless $numkeys =~ /^\d+$/ && $numkeys > 0;
    return (1 .. $numkeys);
}

sub _keys_for_zinterstore {
    my (@args) = @_;
    # ZINTERSTORE destination numkeys key [key ...] [WEIGHTS ...] [AGGREGATE ...]
    return () unless @args >= 2;
    my $numkeys = $args[1];
    return () unless $numkeys =~ /^\d+$/ && $numkeys > 0;
    return (0, 2 .. 1 + $numkeys);  # dest + source keys
}

sub _keys_for_sintercard {
    my (@args) = @_;
    # SINTERCARD numkeys key [key ...] [LIMIT limit]
    return () unless @args >= 1;
    my $numkeys = $args[0];
    return () unless $numkeys =~ /^\d+$/ && $numkeys > 0;
    return (1 .. $numkeys);
}

sub _keys_for_zmpop {
    my (@args) = @_;
    # ZMPOP numkeys key [key ...] MIN|MAX [COUNT count]
    return () unless @args >= 1;
    my $numkeys = $args[0];
    return () unless $numkeys =~ /^\d+$/ && $numkeys > 0;
    return (1 .. $numkeys);
}

sub _keys_for_bzmpop {
    my (@args) = @_;
    # BZMPOP timeout numkeys key [key ...] MIN|MAX [COUNT count]
    return () unless @args >= 2;
    my $numkeys = $args[1];
    return () unless $numkeys =~ /^\d+$/ && $numkeys > 0;
    return (2 .. 1 + $numkeys);
}

sub _keys_for_xinfo {
    my (@args) = @_;
    # XINFO STREAM key, XINFO GROUPS key, etc.
    return () unless @args >= 2;
    my $subcmd = uc($args[0]);
    if ($subcmd =~ /^(STREAM|GROUPS|CONSUMERS)$/) {
        return (1);
    }
    return ();
}

sub _keys_for_xgroup {
    my (@args) = @_;
    # XGROUP CREATE key groupname id, XGROUP DESTROY key groupname, etc.
    return () unless @args >= 2;
    my $subcmd = uc($args[0]);
    if ($subcmd =~ /^(CREATE|DESTROY|SETID|DELCONSUMER|CREATECONSUMER)$/) {
        return (1);
    }
    return ();
}

sub _keys_for_georadius {
    my (@args) = @_;
    my @indices = (0);  # First arg is always key

    # Look for STORE and STOREDIST
    for my $i (0 .. $#args - 1) {
        if (uc($args[$i]) =~ /^(STORE|STOREDIST)$/) {
            push @indices, $i + 1;
        }
    }

    return @indices;
}

1;

__END__

=head1 NAME

Async::Redis::KeyExtractor - Key position detection for Redis commands

=head1 SYNOPSIS

    use Async::Redis::KeyExtractor;

    # Get indices of key arguments
    my @indices = Async::Redis::KeyExtractor::extract_key_indices(
        'MSET', 'k1', 'v1', 'k2', 'v2'
    );
    # @indices = (0, 2)

    # Apply prefix to keys only
    my @args = Async::Redis::KeyExtractor::apply_prefix(
        'myapp:', 'MSET', 'k1', 'v1', 'k2', 'v2'
    );
    # @args = ('myapp:k1', 'v1', 'myapp:k2', 'v2')

=head1 DESCRIPTION

This module handles the complex task of identifying which arguments to Redis
commands are keys (and should receive namespace prefixes) vs values/options
(which should not be modified).

=cut
```

### Step 5: Run unit test to verify it passes

Run: `prove -l t/01-unit/key-extractor.t`
Expected: PASS

### Step 6: Write integration test for prefixing

```perl
# t/20-commands/prefix.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $redis = eval {
        my $r = Async::Redis->new(
            host   => 'localhost',
            prefix => 'test:prefix:',
            connect_timeout => 2,
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $redis;

    subtest 'prefix applied to SET/GET' => sub {
        $loop->await($redis->set('key1', 'value1'));

        # Value should be stored under prefixed key
        my $raw_redis = Async::Redis->new(host => 'localhost');
        $loop->await($raw_redis->connect);

        my $value = $loop->await($raw_redis->get('test:prefix:key1'));
        is($value, 'value1', 'key stored with prefix');

        # Our prefixed client should find it
        $value = $loop->await($redis->get('key1'));
        is($value, 'value1', 'prefixed GET works');

        # Cleanup via raw connection
        $loop->await($raw_redis->del('test:prefix:key1'));
    };

    subtest 'prefix applied to MGET' => sub {
        my $raw_redis = Async::Redis->new(host => 'localhost');
        $loop->await($raw_redis->connect);

        # Set up keys with prefix
        $loop->await($raw_redis->set('test:prefix:a', '1'));
        $loop->await($raw_redis->set('test:prefix:b', '2'));
        $loop->await($raw_redis->set('test:prefix:c', '3'));

        # MGET with prefixed client
        my $values = $loop->await($redis->mget('a', 'b', 'c'));
        is($values, ['1', '2', '3'], 'MGET with prefix works');

        # Cleanup
        $loop->await($raw_redis->del('test:prefix:a', 'test:prefix:b', 'test:prefix:c'));
    };

    subtest 'prefix NOT applied to values' => sub {
        $loop->await($redis->set('key2', 'my:value:with:colons'));

        my $raw_redis = Async::Redis->new(host => 'localhost');
        $loop->await($raw_redis->connect);

        my $value = $loop->await($raw_redis->get('test:prefix:key2'));
        is($value, 'my:value:with:colons', 'value not prefixed');

        # Cleanup
        $loop->await($raw_redis->del('test:prefix:key2'));
    };

    subtest 'prefix in MSET - keys only, not values' => sub {
        $loop->await($redis->mset('x', 'val:x', 'y', 'val:y'));

        my $raw_redis = Async::Redis->new(host => 'localhost');
        $loop->await($raw_redis->connect);

        my $x = $loop->await($raw_redis->get('test:prefix:x'));
        my $y = $loop->await($raw_redis->get('test:prefix:y'));
        is($x, 'val:x', 'x value unchanged');
        is($y, 'val:y', 'y value unchanged');

        # Cleanup
        $loop->await($raw_redis->del('test:prefix:x', 'test:prefix:y'));
    };

    subtest 'prefix in hash commands' => sub {
        $loop->await($redis->hset('myhash', 'field1', 'value1'));

        my $raw_redis = Async::Redis->new(host => 'localhost');
        $loop->await($raw_redis->connect);

        # Check it's stored with prefix
        my $value = $loop->await($raw_redis->hget('test:prefix:myhash', 'field1'));
        is($value, 'value1', 'hash stored with prefixed key');

        # Field name should NOT be prefixed
        my $exists = $loop->await($raw_redis->hexists('test:prefix:myhash', 'field1'));
        is($exists, 1, 'field name not prefixed');

        # Cleanup
        $loop->await($raw_redis->del('test:prefix:myhash'));
    };

    subtest 'DEL with multiple keys' => sub {
        my $raw_redis = Async::Redis->new(host => 'localhost');
        $loop->await($raw_redis->connect);

        $loop->await($raw_redis->set('test:prefix:d1', '1'));
        $loop->await($raw_redis->set('test:prefix:d2', '2'));
        $loop->await($raw_redis->set('test:prefix:d3', '3'));

        # Delete via prefixed client
        my $deleted = $loop->await($redis->del('d1', 'd2', 'd3'));
        is($deleted, 3, 'DEL with prefix deleted 3 keys');

        # Verify deleted
        my $exists = $loop->await($raw_redis->exists('test:prefix:d1'));
        is($exists, 0, 'key deleted');
    };

    subtest 'no prefix when disabled' => sub {
        my $no_prefix = Async::Redis->new(host => 'localhost');
        $loop->await($no_prefix->connect);

        $loop->await($no_prefix->set('raw:key', 'value'));
        my $value = $loop->await($no_prefix->get('raw:key'));
        is($value, 'value', 'no prefix client works');

        # Cleanup
        $loop->await($no_prefix->del('raw:key'));
    };
}

done_testing;
```

### Step 7: Add prefix support to Async::Redis

Edit `lib/Future/IO/Redis.pm` to add prefix option and use KeyExtractor:

```perl
# In new(), add:
prefix => $args{prefix},

# In command(), add prefixing:
use Async::Redis::KeyExtractor;

sub command {
    my ($self, $cmd, @args) = @_;

    # Apply key prefixing if configured
    if (defined $self->{prefix} && $self->{prefix} ne '') {
        @args = Async::Redis::KeyExtractor::apply_prefix(
            $self->{prefix}, $cmd, @args
        );
    }

    # ... rest of command implementation
}
```

### Step 8: Run integration test

Run: `prove -l t/20-commands/prefix.t`
Expected: PASS (or SKIP if Redis not available)

### Step 9: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 10: Commit

```bash
git add lib/Future/IO/Redis/KeyExtractor.pm share/key_overrides.json \
        t/01-unit/key-extractor.t t/20-commands/prefix.t lib/Future/IO/Redis.pm
git commit -m "$(cat <<'EOF'
feat: add key extraction and namespace prefixing

KeyExtractor.pm:
- Identifies key positions for all Redis commands
- Handles complex cases: EVAL numkeys, XREAD STREAMS, MIGRATE KEYS
- Pattern-based fallbacks for unknown commands
- apply_prefix() prefixes only key arguments

Integration:
- New 'prefix' option in Async::Redis->new()
- Automatic key prefixing in command() method
- Values, field names, options NOT prefixed

Test coverage:
- 20+ unit tests for key extraction
- Integration tests for prefixed operations
- Verified MSET, MGET, hash commands work correctly

EOF
)"
```

---

## Execution Checklist

Before starting each task:
- [ ] All existing tests pass (`prove -l t/`)
- [ ] Non-blocking proof passes (`prove -l t/02-nonblocking.t`)

After completing each task:
- [ ] New tests pass
- [ ] All tests pass (no regressions)
- [ ] Non-blocking proof passes
- [ ] Changes committed

---

## Phase 2 Summary

| Task | Deliverable | Tests |
|------|-------------|-------|
| 7 | `bin/generate-commands`, `share/commands.json` | `t/01-unit/generate-commands.t` |
| 8 | `lib/Future/IO/Redis/Commands.pm` | `t/01-unit/commands.t`, `t/20-commands/*.t` |
| 9 | `lib/Future/IO/Redis/KeyExtractor.pm` | `t/01-unit/key-extractor.t`, `t/20-commands/prefix.t` |

**Total new files:** 12
**Estimated tests:** 150+ assertions

---

## Next Phase

After Phase 2 is complete, Phase 3 will cover:
- **Task 10:** Transactions (MULTI/EXEC/WATCH)
- **Task 11:** Lua Scripting (EVAL/EVALSHA)
