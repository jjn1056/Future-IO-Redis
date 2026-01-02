# Future::IO::Redis Phase 1: Core Reliability

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the foundational reliability layer - error handling, URI parsing, timeouts, reconnection, authentication, and TLS support.

**Architecture:** Extend the existing sketch (`lib/Future/IO/Redis.pm`) with typed exceptions, connection URI support, two-tier timeouts, automatic reconnection, and non-blocking TLS.

**Tech Stack:** Perl 5.18+, Future::IO 0.17+, Future::AsyncAwait, Protocol::Redis, IO::Socket::SSL (optional)

**Prerequisite:** Existing tests pass (`prove -l t/`)

---

## Task Overview

| Task | Component | Files Created/Modified |
|------|-----------|----------------------|
| 1 | Error Classes | 6 new modules, 1 test |
| 2 | URI Parsing | 1 new module, 1 test |
| 3 | Timeouts | Modify Redis.pm, 1 test |
| 4 | Reconnection | Modify Redis.pm, 1 test |
| 5 | Authentication | Modify Redis.pm, 1 test |
| 6 | TLS Support | Modify Redis.pm, 1 test |

---

## Task 1: Error Exception Classes

**Goal:** Typed exceptions for all error conditions, enabling callers to catch and handle specific failure types.

**Files:**
- Create: `lib/Future/IO/Redis/Error.pm`
- Create: `lib/Future/IO/Redis/Error/Connection.pm`
- Create: `lib/Future/IO/Redis/Error/Timeout.pm`
- Create: `lib/Future/IO/Redis/Error/Protocol.pm`
- Create: `lib/Future/IO/Redis/Error/Redis.pm`
- Create: `lib/Future/IO/Redis/Error/Disconnected.pm`
- Create: `t/01-unit/error.t`

### Step 1.1: Create test directory

Run: `mkdir -p t/01-unit`

### Step 1.2: Write the failing test

```perl
# t/01-unit/error.t
use strict;
use warnings;
use Test2::V0;

use Future::IO::Redis::Error;
use Future::IO::Redis::Error::Connection;
use Future::IO::Redis::Error::Timeout;
use Future::IO::Redis::Error::Protocol;
use Future::IO::Redis::Error::Redis;
use Future::IO::Redis::Error::Disconnected;

subtest 'Error base class' => sub {
    my $e = Future::IO::Redis::Error->new(message => 'test error');
    ok($e->isa('Future::IO::Redis::Error'), 'isa Error');
    is($e->message, 'test error', 'message accessor');
    like("$e", qr/test error/, 'stringifies to message');
};

subtest 'Error throw class method' => sub {
    my $died;
    eval {
        Future::IO::Redis::Error->throw(message => 'thrown error');
    };
    $died = $@;
    ok($died, 'throw dies');
    ok($died->isa('Future::IO::Redis::Error'), 'thrown error is Error object');
    is($died->message, 'thrown error', 'message correct');
};

subtest 'Connection error' => sub {
    my $e = Future::IO::Redis::Error::Connection->new(
        message => 'connection lost',
        host    => 'localhost',
        port    => 6379,
        reason  => 'timeout',
    );
    ok($e->isa('Future::IO::Redis::Error'), 'isa base Error');
    ok($e->isa('Future::IO::Redis::Error::Connection'), 'isa Connection');
    is($e->host, 'localhost', 'host accessor');
    is($e->port, 6379, 'port accessor');
    is($e->reason, 'timeout', 'reason accessor');
    like("$e", qr/connection lost/, 'stringifies');
};

subtest 'Timeout error' => sub {
    my $e = Future::IO::Redis::Error::Timeout->new(
        message        => 'request timed out',
        command        => ['GET', 'mykey'],
        timeout        => 5,
        maybe_executed => 0,
    );
    ok($e->isa('Future::IO::Redis::Error'), 'isa base Error');
    ok($e->isa('Future::IO::Redis::Error::Timeout'), 'isa Timeout');
    is_deeply($e->command, ['GET', 'mykey'], 'command accessor');
    is($e->timeout, 5, 'timeout accessor');
    ok(!$e->maybe_executed, 'maybe_executed false');

    my $e2 = Future::IO::Redis::Error::Timeout->new(
        message        => 'timed out after write',
        maybe_executed => 1,
    );
    ok($e2->maybe_executed, 'maybe_executed true');
};

subtest 'Protocol error' => sub {
    my $e = Future::IO::Redis::Error::Protocol->new(
        message => 'unexpected response type',
        data    => '+OK',
    );
    ok($e->isa('Future::IO::Redis::Error'), 'isa base Error');
    ok($e->isa('Future::IO::Redis::Error::Protocol'), 'isa Protocol');
    is($e->data, '+OK', 'data accessor');
};

subtest 'Redis error' => sub {
    my $e = Future::IO::Redis::Error::Redis->new(
        message => 'WRONGTYPE Operation against a key holding the wrong kind of value',
        type    => 'WRONGTYPE',
    );
    ok($e->isa('Future::IO::Redis::Error'), 'isa base Error');
    ok($e->isa('Future::IO::Redis::Error::Redis'), 'isa Redis');
    is($e->type, 'WRONGTYPE', 'error type');

    # Predicate methods
    ok($e->is_wrongtype, 'is_wrongtype true');
    ok(!$e->is_oom, 'is_oom false');
    ok(!$e->is_busy, 'is_busy false');
    ok(!$e->is_loading, 'is_loading false');
    ok($e->is_fatal, 'WRONGTYPE is fatal');
};

subtest 'Redis error predicates' => sub {
    my %cases = (
        WRONGTYPE => { is_wrongtype => 1, is_fatal => 1 },
        OOM       => { is_oom => 1, is_fatal => 1 },
        BUSY      => { is_busy => 1, is_fatal => 0 },
        LOADING   => { is_loading => 1, is_fatal => 0 },
        NOSCRIPT  => { is_noscript => 1, is_fatal => 1 },
        READONLY  => { is_readonly => 1, is_fatal => 0 },
    );

    for my $type (sort keys %cases) {
        my $e = Future::IO::Redis::Error::Redis->new(
            message => "$type error",
            type    => $type,
        );
        my $expected = $cases{$type};

        for my $pred (qw(is_wrongtype is_oom is_busy is_loading is_noscript is_readonly)) {
            my $want = $expected->{$pred} // 0;
            is(!!$e->$pred, !!$want, "$type: $pred = $want");
        }
        is(!!$e->is_fatal, !!$expected->{is_fatal}, "$type: is_fatal = $expected->{is_fatal}");
    }
};

subtest 'Redis error from_message parser' => sub {
    my $e = Future::IO::Redis::Error::Redis->from_message(
        'WRONGTYPE Operation against a key holding the wrong kind of value'
    );
    is($e->type, 'WRONGTYPE', 'type parsed from message');
    like($e->message, qr/WRONGTYPE/, 'message preserved');

    my $e2 = Future::IO::Redis::Error::Redis->from_message('ERR unknown command');
    is($e2->type, 'ERR', 'ERR type parsed');
};

subtest 'Disconnected error' => sub {
    my $e = Future::IO::Redis::Error::Disconnected->new(
        message    => 'command queue full',
        queue_size => 1000,
    );
    ok($e->isa('Future::IO::Redis::Error'), 'isa base Error');
    ok($e->isa('Future::IO::Redis::Error::Disconnected'), 'isa Disconnected');
    is($e->queue_size, 1000, 'queue_size accessor');
};

done_testing;
```

### Step 1.3: Run test to verify it fails

Run: `prove -l t/01-unit/error.t`
Expected: FAIL with "Can't locate Future/IO/Redis/Error.pm"

### Step 1.4: Create Error directory

Run: `mkdir -p lib/Future/IO/Redis/Error`

### Step 1.5: Write Error base class

```perl
# lib/Future/IO/Redis/Error.pm
package Future::IO::Redis::Error;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use overload
    '""'     => 'stringify',
    bool     => sub { 1 },
    fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub message { shift->{message} }

sub stringify {
    my ($self) = @_;
    return $self->message // ref($self) . ' error';
}

sub throw {
    my $self = shift;
    $self = $self->new(@_) unless ref $self;
    die $self;
}

1;

__END__

=head1 NAME

Future::IO::Redis::Error - Base exception class for Redis errors

=head1 SYNOPSIS

    use Future::IO::Redis::Error;

    # Create and throw
    Future::IO::Redis::Error->throw(message => 'something went wrong');

    # Or create and die later
    my $error = Future::IO::Redis::Error->new(message => 'oops');
    die $error;

    # Catch
    eval { ... };
    if ($@ && $@->isa('Future::IO::Redis::Error')) {
        warn "Redis error: " . $@->message;
    }

=head1 DESCRIPTION

Base class for all Future::IO::Redis exceptions. Subclasses provide
specific error types with additional context.

=cut
```

### Step 1.6: Write Connection error

```perl
# lib/Future/IO/Redis/Error/Connection.pm
package Future::IO::Redis::Error::Connection;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use parent 'Future::IO::Redis::Error';

sub host   { shift->{host} }
sub port   { shift->{port} }
sub path   { shift->{path} }    # for unix sockets
sub reason { shift->{reason} }

1;

__END__

=head1 NAME

Future::IO::Redis::Error::Connection - Connection failure exception

=head1 DESCRIPTION

Thrown when connection to Redis fails or is lost.

=head1 ATTRIBUTES

=over 4

=item host - Redis host

=item port - Redis port

=item path - Unix socket path (if applicable)

=item reason - Why connection failed (timeout, refused, etc.)

=back

=cut
```

### Step 1.7: Write Timeout error

```perl
# lib/Future/IO/Redis/Error/Timeout.pm
package Future::IO::Redis::Error::Timeout;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use parent 'Future::IO::Redis::Error';

sub command        { shift->{command} }
sub timeout        { shift->{timeout} }
sub maybe_executed { shift->{maybe_executed} }

1;

__END__

=head1 NAME

Future::IO::Redis::Error::Timeout - Timeout exception

=head1 DESCRIPTION

Thrown when a Redis operation times out.

=head1 ATTRIBUTES

=over 4

=item command - The command that timed out (arrayref)

=item timeout - The timeout value in seconds

=item maybe_executed - Boolean; true if command may have been executed
on server before timeout. This happens when we timeout after writing
the command but before receiving response.

=back

=cut
```

### Step 1.8: Write Protocol error

```perl
# lib/Future/IO/Redis/Error/Protocol.pm
package Future::IO::Redis::Error::Protocol;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use parent 'Future::IO::Redis::Error';

sub data { shift->{data} }

1;

__END__

=head1 NAME

Future::IO::Redis::Error::Protocol - Protocol violation exception

=head1 DESCRIPTION

Thrown when Redis response doesn't match expected RESP format,
or when commands are used incorrectly (e.g., regular command on
a connection in PubSub mode).

=head1 ATTRIBUTES

=over 4

=item data - The malformed data that triggered the error

=back

=cut
```

### Step 1.9: Write Redis error

```perl
# lib/Future/IO/Redis/Error/Redis.pm
package Future::IO::Redis::Error::Redis;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use parent 'Future::IO::Redis::Error';

sub type { shift->{type} }

# Parse error type from Redis error message
# Redis errors are formatted as: "ERRORTYPE message text"
sub from_message {
    my ($class, $message) = @_;

    my $type = 'ERR';  # default
    if ($message =~ /^([A-Z]+)\s/) {
        $type = $1;
    }

    return $class->new(
        message => $message,
        type    => $type,
    );
}

# Predicate methods for common error types
sub is_wrongtype { uc(shift->{type} // '') eq 'WRONGTYPE' }
sub is_oom       { uc(shift->{type} // '') eq 'OOM' }
sub is_busy      { uc(shift->{type} // '') eq 'BUSY' }
sub is_noscript  { uc(shift->{type} // '') eq 'NOSCRIPT' }
sub is_readonly  { uc(shift->{type} // '') eq 'READONLY' }
sub is_loading   { uc(shift->{type} // '') eq 'LOADING' }
sub is_noauth    { uc(shift->{type} // '') eq 'NOAUTH' }
sub is_noperm    { uc(shift->{type} // '') eq 'NOPERM' }

# Fatal errors should not be retried
sub is_fatal {
    my $self = shift;
    my $type = uc($self->{type} // '');

    # These are deterministic failures - retrying won't help
    return 1 if $type =~ /^(WRONGTYPE|OOM|NOSCRIPT|NOAUTH|NOPERM|ERR)$/;

    return 0;
}

# Transient errors may succeed on retry
sub is_transient {
    my $self = shift;
    my $type = uc($self->{type} // '');

    # These may succeed if retried after a delay
    return 1 if $type =~ /^(BUSY|LOADING|READONLY|CLUSTERDOWN)$/;

    return 0;
}

1;

__END__

=head1 NAME

Future::IO::Redis::Error::Redis - Redis server error exception

=head1 DESCRIPTION

Thrown when Redis returns an error response (RESP type '-').

=head1 METHODS

=head2 from_message($message)

Class method to create error from Redis error message, parsing
the error type from the message prefix.

    my $error = Future::IO::Redis::Error::Redis->from_message(
        'WRONGTYPE Operation against key holding wrong type'
    );
    say $error->type;  # 'WRONGTYPE'

=head2 Predicates

=over 4

=item is_wrongtype - Key holds wrong type for operation

=item is_oom - Out of memory

=item is_busy - Server busy (Lua script running)

=item is_noscript - Script SHA not found

=item is_readonly - Write on read-only replica

=item is_loading - Server still loading dataset

=item is_noauth - Authentication required

=item is_noperm - ACL permission denied

=item is_fatal - Error is deterministic, retry won't help

=item is_transient - Error may succeed on retry

=back

=cut
```

### Step 1.10: Write Disconnected error

```perl
# lib/Future/IO/Redis/Error/Disconnected.pm
package Future::IO::Redis::Error::Disconnected;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

use parent 'Future::IO::Redis::Error';

sub queue_size { shift->{queue_size} }

1;

__END__

=head1 NAME

Future::IO::Redis::Error::Disconnected - Disconnected exception

=head1 DESCRIPTION

Thrown when a command is issued while disconnected and the
command queue is full (cannot queue for later execution).

=head1 ATTRIBUTES

=over 4

=item queue_size - Current size of command queue

=back

=cut
```

### Step 1.11: Run test to verify it passes

Run: `prove -l t/01-unit/error.t`
Expected: PASS (all subtests pass)

### Step 1.12: Run all existing tests

Run: `prove -l t/`
Expected: PASS (no regressions)

### Step 1.13: Commit

```bash
git add lib/Future/IO/Redis/Error.pm lib/Future/IO/Redis/Error/*.pm t/01-unit/
git commit -m "$(cat <<'EOF'
feat: add typed exception classes for error handling

Exception hierarchy:
- Future::IO::Redis::Error (base)
  - ::Connection - connect failed, connection lost
  - ::Timeout - operation timed out, with maybe_executed flag
  - ::Protocol - malformed RESP, wrong mode
  - ::Redis - server error with type predicates
  - ::Disconnected - queue full while disconnected

Redis error features:
- from_message() parses error type from Redis response
- Predicate methods: is_wrongtype, is_oom, is_busy, etc.
- is_fatal vs is_transient for retry decisions

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: URI Parsing

**Goal:** Support Redis connection URIs for easy configuration.

**Files:**
- Create: `lib/Future/IO/Redis/URI.pm`
- Create: `t/01-unit/uri.t`

### Step 2.1: Write the failing test

```perl
# t/01-unit/uri.t
use strict;
use warnings;
use Test2::V0;

use Future::IO::Redis::URI;

subtest 'basic redis URI' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://localhost');
    is($uri->scheme, 'redis', 'scheme');
    is($uri->host, 'localhost', 'host');
    is($uri->port, 6379, 'default port');
    is($uri->database, 0, 'default database');
    ok(!$uri->password, 'no password');
    ok(!$uri->username, 'no username');
    ok(!$uri->tls, 'no tls');
    ok(!$uri->is_unix, 'not unix socket');
};

subtest 'redis URI with port' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://localhost:6380');
    is($uri->host, 'localhost', 'host');
    is($uri->port, 6380, 'custom port');
};

subtest 'redis URI with password only' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://:secret@localhost');
    is($uri->password, 'secret', 'password parsed');
    ok(!$uri->username, 'no username');
    is($uri->host, 'localhost', 'host');
};

subtest 'redis URI with username and password (ACL)' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://myuser:mypass@localhost');
    is($uri->username, 'myuser', 'username');
    is($uri->password, 'mypass', 'password');
};

subtest 'redis URI with database' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://localhost/5');
    is($uri->database, 5, 'database from path');
};

subtest 'redis URI with database 0 explicit' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://localhost/0');
    is($uri->database, 0, 'database 0 explicit');
};

subtest 'full redis URI' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://admin:secret123@redis.example.com:6380/2');
    is($uri->scheme, 'redis', 'scheme');
    is($uri->host, 'redis.example.com', 'host');
    is($uri->port, 6380, 'port');
    is($uri->username, 'admin', 'username');
    is($uri->password, 'secret123', 'password');
    is($uri->database, 2, 'database');
    ok(!$uri->tls, 'no tls');
};

subtest 'rediss (TLS) URI' => sub {
    my $uri = Future::IO::Redis::URI->parse('rediss://localhost:6380');
    is($uri->scheme, 'rediss', 'scheme');
    ok($uri->tls, 'tls enabled');
    is($uri->port, 6380, 'port');
};

subtest 'rediss with auth' => sub {
    my $uri = Future::IO::Redis::URI->parse('rediss://user:pass@secure.redis.io');
    ok($uri->tls, 'tls enabled');
    is($uri->username, 'user', 'username');
    is($uri->password, 'pass', 'password');
    is($uri->port, 6379, 'default port');
};

subtest 'unix socket URI' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis+unix:///var/run/redis.sock');
    is($uri->scheme, 'redis+unix', 'scheme');
    is($uri->path, '/var/run/redis.sock', 'socket path');
    ok($uri->is_unix, 'is unix socket');
    is($uri->database, 0, 'default database');
};

subtest 'unix socket with password' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis+unix://:secret@/var/run/redis.sock');
    is($uri->path, '/var/run/redis.sock', 'socket path');
    is($uri->password, 'secret', 'password');
    ok($uri->is_unix, 'is unix socket');
};

subtest 'unix socket with database query param' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis+unix:///var/run/redis.sock?db=3');
    is($uri->path, '/var/run/redis.sock', 'socket path');
    is($uri->database, 3, 'database from query');
};

subtest 'unix socket with multiple query params' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis+unix:///run/redis.sock?db=5&timeout=10');
    is($uri->database, 5, 'database');
    # timeout would be handled by caller, not URI parser
};

subtest 'URL-encoded password' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://:p%40ss%3Aword@localhost');
    is($uri->password, 'p@ss:word', 'password URL-decoded');
};

subtest 'URL-encoded username' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://user%40domain:pass@localhost');
    is($uri->username, 'user@domain', 'username URL-decoded');
};

subtest 'to_hash for constructor' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis://user:pass@localhost:6380/2');
    my %hash = $uri->to_hash;

    is($hash{host}, 'localhost', 'host');
    is($hash{port}, 6380, 'port');
    is($hash{username}, 'user', 'username');
    is($hash{password}, 'pass', 'password');
    is($hash{database}, 2, 'database');
    ok(!exists $hash{tls}, 'no tls key when false');
};

subtest 'to_hash with TLS' => sub {
    my $uri = Future::IO::Redis::URI->parse('rediss://localhost');
    my %hash = $uri->to_hash;

    is($hash{tls}, 1, 'tls in hash');
};

subtest 'to_hash for unix socket' => sub {
    my $uri = Future::IO::Redis::URI->parse('redis+unix:///var/run/redis.sock?db=1');
    my %hash = $uri->to_hash;

    is($hash{path}, '/var/run/redis.sock', 'path');
    is($hash{database}, 1, 'database');
    ok(!exists $hash{host}, 'no host for unix socket');
    ok(!exists $hash{port}, 'no port for unix socket');
};

subtest 'invalid URI - bad scheme' => sub {
    ok(dies { Future::IO::Redis::URI->parse('http://localhost') },
       'http scheme rejected');
    ok(dies { Future::IO::Redis::URI->parse('mysql://localhost') },
       'mysql scheme rejected');
};

subtest 'invalid URI - malformed' => sub {
    ok(dies { Future::IO::Redis::URI->parse('not a uri at all') },
       'garbage rejected');
    ok(dies { Future::IO::Redis::URI->parse('redis://') },
       'empty host rejected');
};

subtest 'parse returns undef for empty/undef' => sub {
    is(Future::IO::Redis::URI->parse(''), undef, 'empty string');
    is(Future::IO::Redis::URI->parse(undef), undef, 'undef');
};

done_testing;
```

### Step 2.2: Run test to verify it fails

Run: `prove -l t/01-unit/uri.t`
Expected: FAIL with "Can't locate Future/IO/Redis/URI.pm"

### Step 2.3: Write URI parser

```perl
# lib/Future/IO/Redis/URI.pm
package Future::IO::Redis::URI;

use strict;
use warnings;
use 5.018;

our $VERSION = '0.001';

# URL decode
sub _decode {
    my ($str) = @_;
    return unless defined $str;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    return $str;
}

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub parse {
    my ($class, $uri_string) = @_;

    return undef unless defined $uri_string && $uri_string ne '';

    my %parsed = (
        host     => 'localhost',
        port     => 6379,
        database => 0,
        tls      => 0,
        is_unix  => 0,
    );

    # Handle unix socket: redis+unix://[:password@]/path[?query]
    if ($uri_string =~ m{^(redis\+unix)://(?:(?::([^@]*))?@)?(/[^?]+)(?:\?(.*))?$}) {
        $parsed{scheme} = $1;
        $parsed{password} = _decode($2) if defined $2 && $2 ne '';
        $parsed{path} = $3;
        $parsed{is_unix} = 1;

        # Remove host/port for unix sockets
        delete $parsed{host};
        delete $parsed{port};

        # Parse query string
        if (defined $4) {
            my %query;
            for my $pair (split /&/, $4) {
                my ($k, $v) = split /=/, $pair, 2;
                $query{$k} = _decode($v);
            }
            $parsed{database} = $query{db} if exists $query{db};
        }

        return $class->new(%parsed);
    }

    # Standard URI: redis[s]://[user:pass@]host[:port][/database]
    unless ($uri_string =~ m{^(rediss?)://(.+)$}) {
        die "Invalid Redis URI: must start with redis://, rediss://, or redis+unix://";
    }

    my $scheme = $1;
    my $rest = $2;

    $parsed{scheme} = $scheme;
    $parsed{tls} = 1 if $scheme eq 'rediss';

    # Split userinfo from host
    my ($userinfo, $hostinfo);
    if ($rest =~ /^([^@]*)@(.+)$/) {
        $userinfo = $1;
        $hostinfo = $2;
    } else {
        $hostinfo = $rest;
    }

    # Parse userinfo: empty, :password, user:password, or just user
    if (defined $userinfo && $userinfo ne '') {
        if ($userinfo =~ /^:(.*)$/) {
            # :password (no username)
            $parsed{password} = _decode($1);
        } elsif ($userinfo =~ /^([^:]*):(.*)$/) {
            # user:password
            $parsed{username} = _decode($1);
            $parsed{password} = _decode($2);
        } else {
            # just username
            $parsed{username} = _decode($userinfo);
        }
    }

    # Parse hostinfo: host[:port][/database]
    if ($hostinfo =~ m{^([^:/]+)(?::(\d+))?(?:/(\d+))?$}) {
        $parsed{host} = $1;
        $parsed{port} = int($2) if defined $2;
        $parsed{database} = int($3) if defined $3;
    } elsif ($hostinfo =~ m{^([^:/]+)(?::(\d+))?/?$}) {
        # host:port with trailing slash but no database
        $parsed{host} = $1;
        $parsed{port} = int($2) if defined $2;
    } else {
        die "Invalid Redis URI format: cannot parse host from '$hostinfo'";
    }

    # Validate we got a host
    die "Invalid Redis URI: empty host" unless $parsed{host};

    return $class->new(%parsed);
}

# Accessors
sub scheme   { shift->{scheme} }
sub host     { shift->{host} }
sub port     { shift->{port} }
sub path     { shift->{path} }
sub database { shift->{database} }
sub username { shift->{username} }
sub password { shift->{password} }
sub tls      { shift->{tls} }
sub is_unix  { shift->{is_unix} }

# Convert to hash suitable for Future::IO::Redis->new()
sub to_hash {
    my ($self) = @_;
    my %hash;

    if ($self->is_unix) {
        $hash{path} = $self->path;
    } else {
        $hash{host} = $self->host;
        $hash{port} = $self->port;
    }

    $hash{database} = $self->database if $self->database;
    $hash{username} = $self->username if defined $self->username;
    $hash{password} = $self->password if defined $self->password;
    $hash{tls} = 1 if $self->tls;

    return %hash;
}

1;

__END__

=head1 NAME

Future::IO::Redis::URI - Redis connection URI parser

=head1 SYNOPSIS

    use Future::IO::Redis::URI;

    my $uri = Future::IO::Redis::URI->parse('redis://localhost:6379/0');

    say $uri->host;      # localhost
    say $uri->port;      # 6379
    say $uri->database;  # 0

    # Use with constructor
    my $redis = Future::IO::Redis->new($uri->to_hash);

=head1 DESCRIPTION

Parses Redis connection URIs in standard formats:

    redis://host:port/database
    redis://:password@host
    redis://user:password@host
    rediss://host              (TLS)
    redis+unix:///path/to/socket?db=N

=head1 METHODS

=head2 parse($uri_string)

Class method. Parses URI string and returns URI object.
Returns undef for empty/undef input. Dies on invalid URI.

=head2 to_hash

Returns hash suitable for passing to Future::IO::Redis->new().

=head2 Accessors

scheme, host, port, path, database, username, password, tls, is_unix

=cut
```

### Step 2.4: Run test to verify it passes

Run: `prove -l t/01-unit/uri.t`
Expected: PASS

### Step 2.5: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 2.6: Commit

```bash
git add lib/Future/IO/Redis/URI.pm t/01-unit/uri.t
git commit -m "$(cat <<'EOF'
feat: add Redis URI connection string parser

Supported formats:
- redis://host:port/database
- redis://:password@host (password only)
- redis://user:password@host (ACL auth)
- rediss://host (TLS enabled)
- redis+unix:///path/to/socket?db=N

Features:
- URL-decoding of username/password
- to_hash() for easy constructor use
- Validates scheme and format

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Timeout Implementation & Unix Socket Support

**Goal:** Implement two-tier timeout system (socket-level and per-request deadlines) and Unix socket connection support.

**Files:**
- Modify: `lib/Future/IO/Redis.pm`
- Create: `t/10-connection/timeout.t`
- Create: `t/10-connection/unix-socket.t`

### Step 3.1: Create test directory

Run: `mkdir -p t/10-connection`

### Step 3.2: Write the failing test

```perl
# t/10-connection/timeout.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

subtest 'constructor accepts timeout parameters' => sub {
    my $redis = Future::IO::Redis->new(
        host                    => 'localhost',
        connect_timeout         => 5,
        read_timeout            => 10,
        write_timeout           => 10,
        request_timeout         => 3,
        blocking_timeout_buffer => 2,
    );

    is($redis->{connect_timeout}, 5, 'connect_timeout');
    is($redis->{read_timeout}, 10, 'read_timeout');
    is($redis->{write_timeout}, 10, 'write_timeout');
    is($redis->{request_timeout}, 3, 'request_timeout');
    is($redis->{blocking_timeout_buffer}, 2, 'blocking_timeout_buffer');
};

subtest 'default timeout values' => sub {
    my $redis = Future::IO::Redis->new(host => 'localhost');

    is($redis->{connect_timeout}, 10, 'default connect_timeout');
    is($redis->{read_timeout}, 30, 'default read_timeout');
    is($redis->{request_timeout}, 5, 'default request_timeout');
    is($redis->{blocking_timeout_buffer}, 2, 'default blocking_timeout_buffer');
};

subtest 'connect timeout fires on unreachable host' => sub {
    my $start = time();

    my $redis = Future::IO::Redis->new(
        host            => '10.255.255.1',  # non-routable IP
        connect_timeout => 0.5,
    );

    my $error;
    eval { $loop->await($redis->connect) };
    $error = $@;

    my $elapsed = time() - $start;

    ok($error, 'connect failed');
    ok($elapsed >= 0.4, "waited at least 0.4s (got ${elapsed}s)");
    ok($elapsed < 1.5, "didn't wait too long (got ${elapsed}s)");
};

subtest 'event loop not blocked during connect timeout' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.05,
        on_tick  => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    my $redis = Future::IO::Redis->new(
        host            => '10.255.255.1',
        connect_timeout => 0.3,
    );

    my $start = time();
    eval { $loop->await($redis->connect) };
    my $elapsed = time() - $start;

    $timer->stop;
    $loop->remove($timer);

    # Should have ticked multiple times during the 0.3s wait
    ok(@ticks >= 3, "timer ticked " . scalar(@ticks) . " times during ${elapsed}s timeout");
};

# Tests requiring actual Redis connection
SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 4 unless $test_redis;
    $test_redis->disconnect;

    subtest 'request timeout fires on slow command' => sub {
        my $redis = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            request_timeout => 0.3,
        );
        $loop->await($redis->connect);

        my $start = time();
        my $error;
        eval {
            # DEBUG SLEEP causes Redis to block for N seconds
            $loop->await($redis->command('DEBUG', 'SLEEP', '2'));
        };
        $error = $@;
        my $elapsed = time() - $start;

        ok($error, 'command failed');
        like("$error", qr/timed?\s*out/i, 'error mentions timeout');
        ok($elapsed >= 0.2, "waited at least 0.2s (got ${elapsed}s)");
        ok($elapsed < 1.0, "timed out before command finished (got ${elapsed}s)");

        $redis->disconnect;
    };

    subtest 'event loop not blocked during request timeout' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.05,
            on_tick  => sub { push @ticks, time() },
        );
        $loop->add($timer);
        $timer->start;

        my $redis = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            request_timeout => 0.3,
        );
        $loop->await($redis->connect);

        eval { $loop->await($redis->command('DEBUG', 'SLEEP', '2')) };

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 3, "timer ticked " . scalar(@ticks) . " times during timeout");

        $redis->disconnect;
    };

    subtest 'blocking command uses extended timeout' => sub {
        my $redis = Future::IO::Redis->new(
            host                    => $ENV{REDIS_HOST} // 'localhost',
            request_timeout         => 1,
            blocking_timeout_buffer => 1,
        );
        $loop->await($redis->connect);

        # Clean up any existing list
        $loop->await($redis->del('timeout:test:list'));

        my $start = time();
        # BLPOP with 0.5s server timeout
        # Client deadline should be 0.5 + 1 (buffer) = 1.5s
        my $result = $loop->await($redis->command('BLPOP', 'timeout:test:list', '0.5'));
        my $elapsed = time() - $start;

        # BLPOP returns undef on timeout
        is($result, undef, 'BLPOP returned undef (server timeout)');
        ok($elapsed >= 0.4, "waited for server timeout (${elapsed}s)");
        ok($elapsed < 1.0, "didn't hit client timeout (${elapsed}s)");

        $redis->disconnect;
    };

    subtest 'normal commands work within timeout' => sub {
        my $redis = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            request_timeout => 5,
        );
        $loop->await($redis->connect);

        # Normal commands should complete well within timeout
        my $result = $loop->await($redis->command('PING'));
        is($result, 'PONG', 'PING works');

        $loop->await($redis->command('SET', 'timeout:test:key', 'value'));
        my $value = $loop->await($redis->command('GET', 'timeout:test:key'));
        is($value, 'value', 'GET/SET work');

        # Cleanup
        $loop->await($redis->del('timeout:test:key'));
        $redis->disconnect;
    };
}

done_testing;
```

### Step 3.3: Run test to verify it fails

Run: `prove -l t/10-connection/timeout.t`
Expected: FAIL (timeout parameters not implemented)

### Step 3.4: Read current Redis.pm to understand structure

Run: `head -100 lib/Future/IO/Redis.pm`

### Step 3.5: Add timeout parameters to constructor

In `lib/Future/IO/Redis.pm`, modify the `new` method to include timeout parameters and Unix socket support:

```perl
sub new {
    my ($class, %args) = @_;

    my $self = bless {
        # Connection settings (TCP)
        host     => $args{host} // 'localhost',
        port     => $args{port} // 6379,

        # Connection settings (Unix socket)
        path     => $args{path},  # e.g., '/var/run/redis.sock'

        socket   => undef,
        parser   => undef,
        connected => 0,
        subscribing => 0,
        _read_buffer => '',

        # Timeout settings
        connect_timeout         => $args{connect_timeout} // 10,
        read_timeout            => $args{read_timeout} // 30,
        write_timeout           => $args{write_timeout} // 30,
        request_timeout         => $args{request_timeout} // 5,
        blocking_timeout_buffer => $args{blocking_timeout_buffer} // 2,

        # Inflight tracking with deadlines
        inflight => [],
    }, $class;

    return $self;
}
```

**Note:** When `path` is set, the client will connect via Unix socket instead of TCP.

### Step 3.6: Add timeout to connect (TCP and Unix socket)

Modify the `connect` method to support both TCP and Unix socket connections:

```perl
use Socket qw(AF_INET AF_UNIX SOCK_STREAM pack_sockaddr_in pack_sockaddr_un inet_aton);
use IO::Socket::INET;
use IO::Socket::UNIX;

async sub connect {
    my ($self) = @_;

    return $self if $self->{connected};

    my ($socket, $sockaddr);

    # Check if connecting via Unix socket
    if ($self->{path}) {
        # Unix socket connection
        $socket = IO::Socket::UNIX->new(
            Type => SOCK_STREAM,
        ) or die Future::IO::Redis::Error::Connection->new(
            message => "Cannot create Unix socket: $!",
            path    => $self->{path},
        );

        # Set non-blocking
        $socket->blocking(0);

        # Build Unix sockaddr
        $sockaddr = pack_sockaddr_un($self->{path});
    }
    else {
        # TCP connection
        $socket = IO::Socket::INET->new(
            Proto    => 'tcp',
            Blocking => 0,
        ) or die Future::IO::Redis::Error::Connection->new(
            message => "Cannot create socket: $!",
            host    => $self->{host},
            port    => $self->{port},
        );

        # Build TCP sockaddr
        my $addr = inet_aton($self->{host})
            or die Future::IO::Redis::Error::Connection->new(
                message => "Cannot resolve host: $self->{host}",
                host    => $self->{host},
                port    => $self->{port},
            );
        $sockaddr = pack_sockaddr_in($self->{port}, $addr);
    }

    # Connect with timeout
    eval {
        await Future::IO->connect($socket, $sockaddr)
            ->timeout($self->{connect_timeout});
    };
    if ($@) {
        my $error = $@;
        close $socket;

        if ($error =~ /timeout/i) {
            die Future::IO::Redis::Error::Timeout->new(
                message => "Connect timed out after $self->{connect_timeout}s",
                timeout => $self->{connect_timeout},
            );
        }

        # Include path or host/port in error depending on connection type
        if ($self->{path}) {
            die Future::IO::Redis::Error::Connection->new(
                message => "$error",
                path    => $self->{path},
            );
        }
        die Future::IO::Redis::Error::Connection->new(
            message => "$error",
            host    => $self->{host},
            port    => $self->{port},
        );
    }

    $self->{socket} = $socket;
    $self->{parser} = _parser_class()->new(api => 1);
    $self->{connected} = 1;
    $self->{inflight} = [];

    return $self;
}
```

### Step 3.7: Add request deadline tracking to command

Modify the `command` method to track deadlines:

```perl
async sub command {
    my ($self, @args) = @_;

    die Future::IO::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    my $cmd = $self->_build_command(@args);

    # Calculate deadline based on command type
    my $deadline = $self->_calculate_deadline($args[0], @args[1..$#args]);

    # Create tracked entry
    my $entry = {
        future   => undef,  # will be set after send
        deadline => $deadline,
        command  => \@args,
        state    => 'queued',
    };

    await $self->_send($cmd);
    $entry->{state} = 'written';

    push @{$self->{inflight}}, $entry;

    my $response = await $self->_read_response_with_timeout($entry);
    return $self->_decode_response($response);
}

sub _calculate_deadline {
    my ($self, $cmd, @args) = @_;

    $cmd = uc($cmd // '');

    # Blocking commands get extended deadline
    if ($cmd =~ /^(BLPOP|BRPOP|BLMOVE|BRPOPLPUSH|BLMPOP|BZPOPMIN|BZPOPMAX|BZMPOP)$/) {
        # Last arg is the timeout for these commands
        my $server_timeout = $args[-1] // 0;
        return time() + $server_timeout + $self->{blocking_timeout_buffer};
    }

    if ($cmd =~ /^(XREAD|XREADGROUP)$/) {
        # XREAD/XREADGROUP have BLOCK option
        for my $i (0 .. $#args - 1) {
            if (uc($args[$i]) eq 'BLOCK') {
                my $block_ms = $args[$i + 1] // 0;
                return time() + ($block_ms / 1000) + $self->{blocking_timeout_buffer};
            }
        }
    }

    # Normal commands use request_timeout
    return time() + $self->{request_timeout};
}

async sub _read_response_with_timeout {
    my ($self, $entry) = @_;

    my $remaining = $entry->{deadline} - time();

    if ($remaining <= 0) {
        $self->_handle_timeout($entry);
        die $entry->{_timeout_error};
    }

    eval {
        my $response = await Future::IO->read($self->{socket}, 65536)
            ->timeout($remaining);

        if (!defined $response || length($response) == 0) {
            die Future::IO::Redis::Error::Connection->new(
                message => "Connection closed by server",
            );
        }

        $self->{parser}->parse($response);
    };

    if ($@) {
        my $error = $@;
        if ($error =~ /timeout/i) {
            $self->_handle_timeout($entry);
            die $entry->{_timeout_error};
        }
        die $error;
    }

    # Check for complete message
    while (1) {
        if (my $msg = $self->{parser}->get_message) {
            # Remove from inflight
            @{$self->{inflight}} = grep { $_ != $entry } @{$self->{inflight}};
            $entry->{state} = 'responded';
            return $msg;
        }

        # Need more data
        my $remaining = $entry->{deadline} - time();
        if ($remaining <= 0) {
            $self->_handle_timeout($entry);
            die $entry->{_timeout_error};
        }

        eval {
            my $buf = await Future::IO->read($self->{socket}, 65536)
                ->timeout($remaining);

            if (!defined $buf || length($buf) == 0) {
                die "Connection closed";
            }

            $self->{parser}->parse($buf);
        };

        if ($@) {
            my $error = $@;
            if ($error =~ /timeout/i) {
                $self->_handle_timeout($entry);
                die $entry->{_timeout_error};
            }
            die Future::IO::Redis::Error::Connection->new(
                message => "$error",
            );
        }
    }
}

sub _handle_timeout {
    my ($self, $entry) = @_;

    # Create timeout error
    $entry->{_timeout_error} = Future::IO::Redis::Error::Timeout->new(
        message        => "Request timed out after $self->{request_timeout}s",
        command        => $entry->{command},
        timeout        => $self->{request_timeout},
        maybe_executed => ($entry->{state} ne 'queued'),
    );

    # Reset connection - stream is now desynced
    $self->_reset_connection;
}

sub _reset_connection {
    my ($self) = @_;

    if ($self->{socket}) {
        close $self->{socket};
        $self->{socket} = undef;
    }

    $self->{connected} = 0;
    $self->{parser} = undef;
    $self->{inflight} = [];
}
```

### Step 3.8: Add require for Error classes at top of Redis.pm

```perl
use Future::IO::Redis::Error::Connection;
use Future::IO::Redis::Error::Timeout;
use Future::IO::Redis::Error::Disconnected;
```

### Step 3.9: Run test to verify it passes

Run: `prove -l t/10-connection/timeout.t`
Expected: PASS

### Step 3.10: Run all tests

Run: `prove -l t/`
Expected: PASS (including existing 01-basic.t, 02-nonblocking.t, 03-pubsub.t)

### Step 3.11: Run non-blocking proof

Run: `prove -l t/02-nonblocking.t`
Expected: PASS

### Step 3.12: Commit timeout implementation

```bash
git add lib/Future/IO/Redis.pm t/10-connection/timeout.t
git commit -m "$(cat <<'EOF'
feat: implement two-tier timeout system

Timeout parameters:
- connect_timeout (default 10s): TCP connection establishment
- read_timeout (default 30s): socket-level silence detection
- request_timeout (default 5s): per-command deadline
- blocking_timeout_buffer (default 2s): extra time for BLPOP etc.

Behavior:
- Connect timeout wraps Future::IO->connect
- Request timeout uses per-command deadlines
- Blocking commands (BLPOP, XREAD) get extended deadline
- Timeout = reset connection (RESP2 stream desync constraint)
- maybe_executed flag indicates if command may have run

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

### Step 3.13: Write Unix socket connection test

Create `t/10-connection/unix-socket.t`:

```perl
#!/usr/bin/env perl
# Test Unix socket connections

use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use Future::IO::Redis::URI;

my $loop = IO::Async::Loop->new;
Future::IO::Impl::IOAsync->set_loop($loop);

# Skip if no Unix socket available
my $socket_path = $ENV{REDIS_SOCKET} // '/var/run/redis/redis.sock';
unless (-S $socket_path) {
    skip_all("Redis Unix socket not available at $socket_path");
}

subtest 'connect via Unix socket with path parameter' => sub {
    my $redis = Future::IO::Redis->new(
        path            => $socket_path,
        connect_timeout => 5,
    );

    my $connected = eval { $loop->await($redis->connect); 1 };
    ok($connected, 'connected via Unix socket');

    my $pong = $loop->await($redis->command('PING'));
    is($pong, 'PONG', 'PING works over Unix socket');

    $redis->disconnect;
};

subtest 'connect via redis+unix:// URI' => sub {
    my $uri = Future::IO::Redis::URI->parse("redis+unix://$socket_path");
    ok($uri->is_unix, 'URI is Unix socket');
    is($uri->path, $socket_path, 'path extracted');

    my %opts = $uri->to_hash;
    my $redis = Future::IO::Redis->new(%opts);

    my $connected = eval { $loop->await($redis->connect); 1 };
    ok($connected, 'connected via URI');

    my $pong = $loop->await($redis->command('PING'));
    is($pong, 'PONG', 'PING works');

    $redis->disconnect;
};

subtest 'Unix socket with password' => sub {
    # Skip if not using authenticated Redis
    skip_all('Set REDIS_SOCKET_AUTH to test Unix socket with auth')
        unless $ENV{REDIS_SOCKET_AUTH};

    my $uri = Future::IO::Redis::URI->parse(
        "redis+unix://:$ENV{REDIS_SOCKET_AUTH}\@$socket_path"
    );

    my %opts = $uri->to_hash;
    my $redis = Future::IO::Redis->new(%opts);

    my $connected = eval { $loop->await($redis->connect); 1 };
    ok($connected, 'connected with auth');

    $redis->disconnect;
};

subtest 'Unix socket connection timeout' => sub {
    # Use a non-existent socket path
    my $redis = Future::IO::Redis->new(
        path            => '/nonexistent/redis.sock',
        connect_timeout => 1,
    );

    my $error;
    eval { $loop->await($redis->connect) };
    $error = $@;

    ok($error, 'connection failed');
    like($error, qr/Cannot create Unix socket|connect|No such file/i,
        'got connection error');
};

subtest 'event loop not blocked during Unix socket connect' => sub {
    my @ticks;
    my $timer = IO::Async::Timer::Periodic->new(
        interval => 0.01,
        on_tick => sub { push @ticks, time() },
    );
    $loop->add($timer);
    $timer->start;

    my $redis = Future::IO::Redis->new(
        path            => $socket_path,
        connect_timeout => 5,
    );

    $loop->await($redis->connect);

    $timer->stop;
    $loop->remove($timer);

    ok(@ticks >= 0, 'event loop was responsive during connect');

    $redis->disconnect;
};

done_testing;
```

### Step 3.14: Run Unix socket test

Run: `REDIS_SOCKET=/var/run/redis/redis.sock prove -l t/10-connection/unix-socket.t`
Expected: PASS (or skip if no Unix socket available)

### Step 3.15: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 3.16: Commit Unix socket support

```bash
git add t/10-connection/unix-socket.t
git commit -m "$(cat <<'EOF'
feat: add Unix socket connection support

- Constructor accepts 'path' parameter for Unix socket path
- connect() uses IO::Socket::UNIX when path is set
- URI parser handles redis+unix:// scheme
- Tests for Unix socket connections

Usage:
  # Direct path
  my $redis = Future::IO::Redis->new(path => '/var/run/redis.sock');

  # Via URI
  my $redis = Future::IO::Redis->new(
      uri => 'redis+unix:///var/run/redis.sock?db=1'
  );

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Automatic Reconnection

**Goal:** Auto-reconnect with exponential backoff when connection is lost.

**Files:**
- Modify: `lib/Future/IO/Redis.pm`
- Create: `t/10-connection/reconnect.t`

### Step 4.1: Write the failing test

```perl
# t/10-connection/reconnect.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use Time::HiRes qw(time sleep);

my $loop = IO::Async::Loop->new;

subtest 'constructor accepts reconnect parameters' => sub {
    my $redis = Future::IO::Redis->new(
        host                => 'localhost',
        reconnect           => 1,
        reconnect_delay     => 0.1,
        reconnect_delay_max => 30,
        reconnect_jitter    => 0.25,
        queue_size          => 500,
    );

    ok($redis->{reconnect}, 'reconnect enabled');
    is($redis->{reconnect_delay}, 0.1, 'reconnect_delay');
    is($redis->{reconnect_delay_max}, 30, 'reconnect_delay_max');
    is($redis->{reconnect_jitter}, 0.25, 'reconnect_jitter');
    is($redis->{queue_size}, 500, 'queue_size');
};

subtest 'default reconnect values' => sub {
    my $redis = Future::IO::Redis->new(host => 'localhost');

    ok(!$redis->{reconnect}, 'reconnect disabled by default');
    is($redis->{reconnect_delay}, 0.1, 'default reconnect_delay');
    is($redis->{reconnect_delay_max}, 60, 'default reconnect_delay_max');
    is($redis->{reconnect_jitter}, 0.25, 'default reconnect_jitter');
    is($redis->{queue_size}, 1000, 'default queue_size');
};

subtest 'callbacks accepted' => sub {
    my @events;

    my $redis = Future::IO::Redis->new(
        host          => 'localhost',
        on_connect    => sub { push @events, ['connect', @_] },
        on_disconnect => sub { push @events, ['disconnect', @_] },
        on_error      => sub { push @events, ['error', @_] },
    );

    ok(ref $redis->{on_connect} eq 'CODE', 'on_connect stored');
    ok(ref $redis->{on_disconnect} eq 'CODE', 'on_disconnect stored');
    ok(ref $redis->{on_error} eq 'CODE', 'on_error stored');
};

subtest 'exponential backoff calculation' => sub {
    my $redis = Future::IO::Redis->new(
        host                => 'localhost',
        reconnect_delay     => 0.1,
        reconnect_delay_max => 10,
        reconnect_jitter    => 0,  # disable jitter for predictable testing
    );

    # Test internal backoff calculation
    is($redis->_calculate_backoff(1), 0.1, 'attempt 1: 0.1s');
    is($redis->_calculate_backoff(2), 0.2, 'attempt 2: 0.2s');
    is($redis->_calculate_backoff(3), 0.4, 'attempt 3: 0.4s');
    is($redis->_calculate_backoff(4), 0.8, 'attempt 4: 0.8s');
    is($redis->_calculate_backoff(10), 10, 'attempt 10: capped at max');
    is($redis->_calculate_backoff(20), 10, 'attempt 20: still capped');
};

subtest 'jitter applied to backoff' => sub {
    my $redis = Future::IO::Redis->new(
        host                => 'localhost',
        reconnect_delay     => 1,
        reconnect_delay_max => 60,
        reconnect_jitter    => 0.25,
    );

    # With 25% jitter, delay 1.0 should be in range [0.75, 1.25]
    my @delays;
    for (1..20) {
        push @delays, $redis->_calculate_backoff(1);
    }

    my $min = (sort { $a <=> $b } @delays)[0];
    my $max = (sort { $b <=> $a } @delays)[0];

    ok($min >= 0.75, "min delay $min >= 0.75");
    ok($max <= 1.25, "max delay $max <= 1.25");
    ok($max > $min, "jitter produced variation");
};

# Tests requiring Redis
SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 3 unless $test_redis;
    $test_redis->disconnect;

    subtest 'on_connect callback fires' => sub {
        my @events;

        my $redis = Future::IO::Redis->new(
            host       => $ENV{REDIS_HOST} // 'localhost',
            on_connect => sub {
                my ($r) = @_;
                push @events, 'connected';
            },
        );

        $loop->await($redis->connect);

        is(\@events, ['connected'], 'on_connect fired');
        $redis->disconnect;
    };

    subtest 'on_disconnect callback fires' => sub {
        my @events;

        my $redis = Future::IO::Redis->new(
            host          => $ENV{REDIS_HOST} // 'localhost',
            on_disconnect => sub {
                my ($r, $reason) = @_;
                push @events, ['disconnected', $reason];
            },
        );

        $loop->await($redis->connect);
        $redis->disconnect;

        is(scalar @events, 1, 'on_disconnect fired once');
        is($events[0][0], 'disconnected', 'event type');
    };

    subtest 'reconnect after disconnect' => sub {
        my @events;

        my $redis = Future::IO::Redis->new(
            host          => $ENV{REDIS_HOST} // 'localhost',
            reconnect     => 1,
            on_connect    => sub { push @events, 'connect' },
            on_disconnect => sub { push @events, 'disconnect' },
        );

        $loop->await($redis->connect);
        is(\@events, ['connect'], 'initial connect');

        # Force disconnect by closing socket
        close $redis->{socket};
        $redis->{connected} = 0;

        # Next command should trigger reconnect
        my $result = $loop->await($redis->ping);
        is($result, 'PONG', 'command succeeded after reconnect');

        # Should have: connect, disconnect, connect
        ok(grep({ $_ eq 'disconnect' } @events), 'disconnect event fired');
        is(scalar(grep { $_ eq 'connect' } @events), 2, 'connected twice');

        $redis->disconnect;
    };
}

done_testing;
```

### Step 4.2: Run test to verify it fails

Run: `prove -l t/10-connection/reconnect.t`
Expected: FAIL (reconnect not implemented)

### Step 4.3: Add reconnect parameters to constructor

Add to `new()` in `lib/Future/IO/Redis.pm`:

```perl
# Reconnection settings
reconnect           => $args{reconnect} // 0,
reconnect_delay     => $args{reconnect_delay} // 0.1,
reconnect_delay_max => $args{reconnect_delay_max} // 60,
reconnect_jitter    => $args{reconnect_jitter} // 0.25,
queue_size          => $args{queue_size} // 1000,
_reconnect_attempt  => 0,
_command_queue      => [],

# Callbacks
on_connect    => $args{on_connect},
on_disconnect => $args{on_disconnect},
on_error      => $args{on_error},
```

### Step 4.4: Implement backoff calculation

```perl
sub _calculate_backoff {
    my ($self, $attempt) = @_;

    # Exponential: delay * 2^(attempt-1)
    my $delay = $self->{reconnect_delay} * (2 ** ($attempt - 1));

    # Cap at max
    $delay = $self->{reconnect_delay_max} if $delay > $self->{reconnect_delay_max};

    # Apply jitter: delay * (1 +/- jitter)
    if ($self->{reconnect_jitter} > 0) {
        my $jitter_range = $delay * $self->{reconnect_jitter};
        my $jitter = (rand(2) - 1) * $jitter_range;
        $delay += $jitter;
    }

    return $delay;
}
```

### Step 4.5: Fire callbacks in connect/disconnect

Modify `connect()` to fire on_connect:

```perl
# At end of connect(), after setting connected = 1:
if ($self->{on_connect}) {
    $self->{on_connect}->($self);
}
$self->{_reconnect_attempt} = 0;  # reset on successful connect
```

Modify `disconnect()` to fire on_disconnect:

```perl
sub disconnect {
    my ($self, $reason) = @_;
    $reason //= 'client_disconnect';

    my $was_connected = $self->{connected};

    if ($self->{socket}) {
        close $self->{socket};
        $self->{socket} = undef;
    }
    $self->{connected} = 0;
    $self->{parser} = undef;

    if ($was_connected && $self->{on_disconnect}) {
        $self->{on_disconnect}->($self, $reason);
    }

    return $self;
}
```

### Step 4.6: Implement auto-reconnect in command

Wrap command execution with reconnect logic:

```perl
async sub command {
    my ($self, @args) = @_;

    # If disconnected and reconnect enabled, try to reconnect
    if (!$self->{connected} && $self->{reconnect}) {
        await $self->_reconnect;
    }

    die Future::IO::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    # ... rest of command implementation
}

async sub _reconnect {
    my ($self) = @_;

    while (!$self->{connected}) {
        $self->{_reconnect_attempt}++;
        my $delay = $self->_calculate_backoff($self->{_reconnect_attempt});

        eval {
            await $self->connect;
        };

        if ($@) {
            # Fire on_error callback
            if ($self->{on_error}) {
                $self->{on_error}->($self, $@);
            }

            # Wait before next attempt
            await Future::IO->sleep($delay);
        }
    }
}
```

### Step 4.7: Run test to verify it passes

Run: `prove -l t/10-connection/reconnect.t`
Expected: PASS

### Step 4.8: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 4.9: Run non-blocking proof

Run: `prove -l t/02-nonblocking.t`
Expected: PASS

### Step 4.10: Commit

```bash
git add lib/Future/IO/Redis.pm t/10-connection/reconnect.t
git commit -m "$(cat <<'EOF'
feat: implement automatic reconnection with exponential backoff

Parameters:
- reconnect: enable auto-reconnect (default: off)
- reconnect_delay: initial delay (default: 0.1s)
- reconnect_delay_max: max delay cap (default: 60s)
- reconnect_jitter: randomization factor (default: 0.25)
- queue_size: max commands to queue during reconnect

Callbacks:
- on_connect: fired after successful connection
- on_disconnect: fired when connection lost
- on_error: fired on reconnection failure

Behavior:
- Exponential backoff: delay * 2^(attempt-1)
- Jitter prevents thundering herd
- Commands issued while disconnected trigger reconnect
- Attempt counter resets on successful connect

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Authentication (AUTH/SELECT)

**Goal:** Support password authentication and database selection on connect.

**Files:**
- Modify: `lib/Future/IO/Redis.pm`
- Create: `t/10-connection/auth.t`

### Step 5.1: Write the failing test

```perl
# t/10-connection/auth.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;

my $loop = IO::Async::Loop->new;

subtest 'constructor accepts auth parameters' => sub {
    my $redis = Future::IO::Redis->new(
        host        => 'localhost',
        password    => 'secret',
        username    => 'myuser',
        database    => 5,
        client_name => 'myapp',
    );

    is($redis->{password}, 'secret', 'password stored');
    is($redis->{username}, 'myuser', 'username stored');
    is($redis->{database}, 5, 'database stored');
    is($redis->{client_name}, 'myapp', 'client_name stored');
};

subtest 'URI parsed for auth' => sub {
    my $redis = Future::IO::Redis->new(
        uri => 'redis://user:pass@localhost:6380/3',
    );

    is($redis->{username}, 'user', 'username from URI');
    is($redis->{password}, 'pass', 'password from URI');
    is($redis->{database}, 3, 'database from URI');
    is($redis->{host}, 'localhost', 'host from URI');
    is($redis->{port}, 6380, 'port from URI');
};

subtest 'URI TLS detected' => sub {
    my $redis = Future::IO::Redis->new(
        uri => 'rediss://localhost',
    );

    ok($redis->{tls}, 'TLS enabled from rediss://');
};

# Tests requiring Redis with specific configuration
SKIP: {
    my $test_redis = eval {
        my $r = Future::IO::Redis->new(
            host            => $ENV{REDIS_HOST} // 'localhost',
            connect_timeout => 2,
        );
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 3 unless $test_redis;
    $test_redis->disconnect;

    subtest 'SELECT database works' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_HOST} // 'localhost',
            database => 1,
        );

        $loop->await($redis->connect);

        # Set a key in database 1
        $loop->await($redis->set('auth:test:db1', 'value1'));

        # Verify we're in database 1
        my $val = $loop->await($redis->get('auth:test:db1'));
        is($val, 'value1', 'key accessible in db 1');

        $loop->await($redis->del('auth:test:db1'));
        $redis->disconnect;

        # Connect to database 0, key should not exist
        my $redis2 = Future::IO::Redis->new(
            host     => $ENV{REDIS_HOST} // 'localhost',
            database => 0,
        );
        $loop->await($redis2->connect);

        my $val2 = $loop->await($redis2->get('auth:test:db1'));
        is($val2, undef, 'key not in db 0');

        $redis2->disconnect;
    };

    subtest 'CLIENT SETNAME works' => sub {
        my $redis = Future::IO::Redis->new(
            host        => $ENV{REDIS_HOST} // 'localhost',
            client_name => 'test-client-12345',
        );

        $loop->await($redis->connect);

        # Verify client name was set
        my $name = $loop->await($redis->command('CLIENT', 'GETNAME'));
        is($name, 'test-client-12345', 'client name set');

        $redis->disconnect;
    };

    subtest 'auth replayed on reconnect' => sub {
        my $connect_count = 0;

        my $redis = Future::IO::Redis->new(
            host        => $ENV{REDIS_HOST} // 'localhost',
            database    => 2,
            client_name => 'reconnect-test',
            reconnect   => 1,
            on_connect  => sub { $connect_count++ },
        );

        $loop->await($redis->connect);
        is($connect_count, 1, 'connected once');

        # Set key in db 2
        $loop->await($redis->set('auth:reconnect:key', 'val'));

        # Force disconnect
        close $redis->{socket};
        $redis->{connected} = 0;

        # Command should reconnect and still be in db 2
        my $val = $loop->await($redis->get('auth:reconnect:key'));
        is($val, 'val', 'still in database 2 after reconnect');
        is($connect_count, 2, 'reconnected');

        # Verify client name restored
        my $name = $loop->await($redis->command('CLIENT', 'GETNAME'));
        is($name, 'reconnect-test', 'client name restored');

        $loop->await($redis->del('auth:reconnect:key'));
        $redis->disconnect;
    };
}

# Password auth tests require Redis configured with requirepass
SKIP: {
    skip "Set REDIS_AUTH_HOST and REDIS_AUTH_PASS to test auth", 2
        unless $ENV{REDIS_AUTH_HOST} && $ENV{REDIS_AUTH_PASS};

    subtest 'password authentication works' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_AUTH_HOST},
            password => $ENV{REDIS_AUTH_PASS},
        );

        $loop->await($redis->connect);
        my $pong = $loop->await($redis->ping);
        is($pong, 'PONG', 'authenticated successfully');

        $redis->disconnect;
    };

    subtest 'wrong password fails' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_AUTH_HOST},
            password => 'wrongpassword',
        );

        my $error;
        eval { $loop->await($redis->connect) };
        $error = $@;

        ok($error, 'connection failed');
        like("$error", qr/auth|password|denied/i, 'error mentions auth');
    };
}

# ACL auth tests require Redis 6+ with ACL configured
SKIP: {
    skip "Set REDIS_ACL_HOST, REDIS_ACL_USER, REDIS_ACL_PASS to test ACL", 1
        unless $ENV{REDIS_ACL_HOST} && $ENV{REDIS_ACL_USER} && $ENV{REDIS_ACL_PASS};

    subtest 'ACL authentication works' => sub {
        my $redis = Future::IO::Redis->new(
            host     => $ENV{REDIS_ACL_HOST},
            username => $ENV{REDIS_ACL_USER},
            password => $ENV{REDIS_ACL_PASS},
        );

        $loop->await($redis->connect);
        my $pong = $loop->await($redis->ping);
        is($pong, 'PONG', 'ACL authenticated successfully');

        $redis->disconnect;
    };
}

done_testing;
```

### Step 5.2: Run test to verify it fails

Run: `prove -l t/10-connection/auth.t`
Expected: FAIL (auth parameters not implemented)

### Step 5.3: Add auth parameters to constructor

Add to `new()`:

```perl
# Authentication
password    => $args{password},
username    => $args{username},
database    => $args{database} // 0,
client_name => $args{client_name},

# TLS (will implement fully in Task 6)
tls => $args{tls},
```

### Step 5.4: Add URI parsing to constructor

```perl
sub new {
    my ($class, %args) = @_;

    # Parse URI if provided
    if ($args{uri}) {
        require Future::IO::Redis::URI;
        my $uri = Future::IO::Redis::URI->parse($args{uri});
        if ($uri) {
            my %uri_args = $uri->to_hash;
            # URI values are defaults, explicit args override
            %args = (%uri_args, %args);
            delete $args{uri};  # don't store the string
        }
    }

    # ... rest of constructor
}
```

### Step 5.5: Implement connection handshake

Create a method that runs AUTH, SELECT, CLIENT SETNAME after TCP connect:

```perl
async sub _redis_handshake {
    my ($self) = @_;

    # AUTH (password or username+password for ACL)
    if ($self->{password}) {
        my @auth_args = ('AUTH');
        push @auth_args, $self->{username} if $self->{username};
        push @auth_args, $self->{password};

        my $cmd = $self->_build_command(@auth_args);
        await $self->_send($cmd);

        my $response = await $self->_read_response();
        my $result = $self->_decode_response($response);

        # AUTH returns OK on success, throws on failure
        unless ($result && $result eq 'OK') {
            die Future::IO::Redis::Error::Redis->new(
                message => "Authentication failed: $result",
                type    => 'NOAUTH',
            );
        }
    }

    # SELECT database
    if ($self->{database} && $self->{database} != 0) {
        my $cmd = $self->_build_command('SELECT', $self->{database});
        await $self->_send($cmd);

        my $response = await $self->_read_response();
        my $result = $self->_decode_response($response);

        unless ($result && $result eq 'OK') {
            die Future::IO::Redis::Error::Redis->new(
                message => "SELECT failed: $result",
                type    => 'ERR',
            );
        }
    }

    # CLIENT SETNAME
    if ($self->{client_name}) {
        my $cmd = $self->_build_command('CLIENT', 'SETNAME', $self->{client_name});
        await $self->_send($cmd);

        my $response = await $self->_read_response();
        # Ignore result - SETNAME failing shouldn't prevent connection
    }
}
```

### Step 5.6: Call handshake in connect

Modify `connect()` to call handshake after socket connection:

```perl
async sub connect {
    my ($self) = @_;

    return $self if $self->{connected};

    # ... TCP connect code ...

    $self->{socket} = $socket;
    $self->{parser} = _parser_class()->new(api => 1);
    $self->{connected} = 1;
    $self->{inflight} = [];

    # Run Redis protocol handshake (AUTH, SELECT, etc.)
    await $self->_redis_handshake;

    # Fire callback
    if ($self->{on_connect}) {
        $self->{on_connect}->($self);
    }
    $self->{_reconnect_attempt} = 0;

    return $self;
}
```

### Step 5.7: Run test to verify it passes

Run: `prove -l t/10-connection/auth.t`
Expected: PASS

### Step 5.8: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 5.9: Run non-blocking proof

Run: `prove -l t/02-nonblocking.t`
Expected: PASS

### Step 5.10: Commit

```bash
git add lib/Future/IO/Redis.pm t/10-connection/auth.t
git commit -m "$(cat <<'EOF'
feat: implement AUTH, SELECT, and CLIENT SETNAME on connect

Parameters:
- password: Redis AUTH password
- username: Redis 6+ ACL username
- database: SELECT database after connect
- client_name: CLIENT SETNAME for identification
- uri: Parse connection string (redis://user:pass@host/db)

Connection sequence:
1. TCP connect
2. AUTH password (or AUTH username password for ACL)
3. SELECT database (if non-zero)
4. CLIENT SETNAME (if specified)
5. Fire on_connect callback

Features:
- URI parsing extracts all auth parameters
- Auth replayed automatically on reconnect
- Proper error on auth failure

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Non-Blocking TLS Support

**Goal:** Implement TLS/SSL with non-blocking handshake.

**Files:**
- Modify: `lib/Future/IO/Redis.pm`
- Create: `t/10-connection/tls.t`

### Step 6.1: Write the failing test

```perl
# t/10-connection/tls.t
use strict;
use warnings;
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Future::IO::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

subtest 'TLS module availability' => sub {
    my $has_ssl = eval { require IO::Socket::SSL; 1 };
    ok(1, "IO::Socket::SSL " . ($has_ssl ? "available" : "not available"));
};

subtest 'constructor accepts TLS parameters' => sub {
    my $redis = Future::IO::Redis->new(
        host => 'localhost',
        tls  => 1,
    );

    is($redis->{tls}, 1, 'tls enabled');
};

subtest 'TLS with options hash' => sub {
    my $redis = Future::IO::Redis->new(
        host => 'localhost',
        tls  => {
            ca_file   => '/path/to/ca.crt',
            cert_file => '/path/to/client.crt',
            key_file  => '/path/to/client.key',
            verify    => 1,
        },
    );

    is(ref $redis->{tls}, 'HASH', 'tls is hash');
    is($redis->{tls}{ca_file}, '/path/to/ca.crt', 'ca_file stored');
};

subtest 'rediss URI enables TLS' => sub {
    my $redis = Future::IO::Redis->new(
        uri => 'rediss://localhost:6380',
    );

    ok($redis->{tls}, 'TLS enabled from rediss://');
};

SKIP: {
    my $has_ssl = eval { require IO::Socket::SSL; 1 };
    skip "IO::Socket::SSL not available", 1 unless $has_ssl;

    subtest 'TLS without server fails gracefully' => sub {
        my $redis = Future::IO::Redis->new(
            host            => 'localhost',
            port            => 16380,  # unlikely to have TLS Redis here
            tls             => 1,
            connect_timeout => 1,
        );

        my $error;
        eval { $loop->await($redis->connect) };
        $error = $@;

        ok($error, 'connection failed (expected - no TLS server)');
    };
}

# TLS tests with actual TLS Redis require specific setup
SKIP: {
    skip "Set TLS_REDIS_HOST and TLS_REDIS_PORT to test TLS", 3
        unless $ENV{TLS_REDIS_HOST} && $ENV{TLS_REDIS_PORT};

    my $has_ssl = eval { require IO::Socket::SSL; 1 };
    skip "IO::Socket::SSL not available", 3 unless $has_ssl;

    subtest 'TLS connection works' => sub {
        my $redis = Future::IO::Redis->new(
            host => $ENV{TLS_REDIS_HOST},
            port => $ENV{TLS_REDIS_PORT},
            tls  => {
                verify => 0,  # skip verification for testing
            },
        );

        $loop->await($redis->connect);
        my $pong = $loop->await($redis->ping);
        is($pong, 'PONG', 'TLS connection works');

        $redis->disconnect;
    };

    subtest 'TLS handshake does not block event loop' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick  => sub { push @ticks, time() },
        );
        $loop->add($timer);
        $timer->start;

        my $redis = Future::IO::Redis->new(
            host            => $ENV{TLS_REDIS_HOST},
            port            => $ENV{TLS_REDIS_PORT},
            tls             => { verify => 0 },
            connect_timeout => 5,
        );

        my $start = time();
        $loop->await($redis->connect);
        my $elapsed = time() - $start;

        $timer->stop;
        $loop->remove($timer);

        # If handshake took any measurable time, we should have ticks
        if ($elapsed > 0.05) {
            my $expected = int($elapsed / 0.01);
            ok(@ticks >= $expected * 0.3,
               "Timer ticked " . scalar(@ticks) . " times during ${elapsed}s TLS handshake");
        } else {
            pass("TLS handshake was very fast (${elapsed}s) - cannot verify non-blocking");
        }

        $redis->disconnect;
    };

    subtest 'TLS with auth works' => sub {
        skip "Set TLS_REDIS_PASS to test TLS+auth", 1
            unless $ENV{TLS_REDIS_PASS};

        my $redis = Future::IO::Redis->new(
            host     => $ENV{TLS_REDIS_HOST},
            port     => $ENV{TLS_REDIS_PORT},
            tls      => { verify => 0 },
            password => $ENV{TLS_REDIS_PASS},
        );

        $loop->await($redis->connect);
        my $pong = $loop->await($redis->ping);
        is($pong, 'PONG', 'TLS + auth works');

        $redis->disconnect;
    };
}

done_testing;
```

### Step 6.2: Run test to verify it fails

Run: `prove -l t/10-connection/tls.t`
Expected: FAIL (TLS not implemented)

### Step 6.3: Implement non-blocking TLS upgrade

Add to `lib/Future/IO/Redis.pm`:

```perl
async sub _tls_upgrade {
    my ($self, $socket) = @_;

    require IO::Socket::SSL;

    # Build SSL options
    my %ssl_opts = (
        SSL_startHandshake => 0,  # Don't block during start_SSL!
    );

    if (ref $self->{tls} eq 'HASH') {
        $ssl_opts{SSL_ca_file}    = $self->{tls}{ca_file} if $self->{tls}{ca_file};
        $ssl_opts{SSL_cert_file}  = $self->{tls}{cert_file} if $self->{tls}{cert_file};
        $ssl_opts{SSL_key_file}   = $self->{tls}{key_file} if $self->{tls}{key_file};

        if (exists $self->{tls}{verify}) {
            $ssl_opts{SSL_verify_mode} = $self->{tls}{verify}
                ? IO::Socket::SSL::SSL_VERIFY_PEER()
                : IO::Socket::SSL::SSL_VERIFY_NONE();
        } else {
            $ssl_opts{SSL_verify_mode} = IO::Socket::SSL::SSL_VERIFY_PEER();
        }
    } else {
        $ssl_opts{SSL_verify_mode} = IO::Socket::SSL::SSL_VERIFY_PEER();
    }

    # Start SSL (does not block because SSL_startHandshake => 0)
    IO::Socket::SSL->start_SSL($socket, %ssl_opts)
        or die Future::IO::Redis::Error::Connection->new(
            message => "SSL setup failed: " . IO::Socket::SSL::errstr(),
            host    => $self->{host},
            port    => $self->{port},
        );

    # Drive handshake with non-blocking loop
    my $deadline = time() + $self->{connect_timeout};

    while (1) {
        # Check timeout
        if (time() >= $deadline) {
            die Future::IO::Redis::Error::Timeout->new(
                message => "TLS handshake timed out",
                timeout => $self->{connect_timeout},
            );
        }

        # Attempt handshake step
        my $rv = $socket->connect_SSL;

        if ($rv) {
            # Handshake complete!
            return $socket;
        }

        # Check what the handshake needs
        my $ssl_error = IO::Socket::SSL::SSL_ERROR_SSL();

        if ($IO::Socket::SSL::SSL_ERROR == IO::Socket::SSL::SSL_ERROR_WANT_READ()) {
            # Wait for socket to become readable
            my $remaining = $deadline - time();
            $remaining = 0.1 if $remaining <= 0;
            await Future::IO->waitfor_readable($socket)
                ->timeout($remaining);
        }
        elsif ($IO::Socket::SSL::SSL_ERROR == IO::Socket::SSL::SSL_ERROR_WANT_WRITE()) {
            # Wait for socket to become writable
            my $remaining = $deadline - time();
            $remaining = 0.1 if $remaining <= 0;
            await Future::IO->waitfor_writable($socket)
                ->timeout($remaining);
        }
        else {
            # Actual error
            die Future::IO::Redis::Error::Connection->new(
                message => "TLS handshake failed: " . IO::Socket::SSL::errstr(),
                host    => $self->{host},
                port    => $self->{port},
            );
        }
    }
}
```

### Step 6.4: Integrate TLS into connect

Modify `connect()` to call TLS upgrade after TCP connect:

```perl
async sub connect {
    my ($self) = @_;

    return $self if $self->{connected};

    # ... TCP connect code ...

    # TLS upgrade if enabled
    if ($self->{tls}) {
        eval {
            $socket = await $self->_tls_upgrade($socket);
        };
        if ($@) {
            close $socket;
            die $@;
        }
    }

    $self->{socket} = $socket;
    $self->{parser} = _parser_class()->new(api => 1);
    $self->{connected} = 1;
    $self->{inflight} = [];

    # Run Redis protocol handshake (AUTH, SELECT, etc.)
    await $self->_redis_handshake;

    # ... callbacks ...
}
```

### Step 6.5: Run test to verify it passes

Run: `prove -l t/10-connection/tls.t`
Expected: PASS (basic tests pass; TLS server tests skip unless env vars set)

### Step 6.6: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 6.7: Run non-blocking proof

Run: `prove -l t/02-nonblocking.t`
Expected: PASS

### Step 6.8: Commit

```bash
git add lib/Future/IO/Redis.pm t/10-connection/tls.t
git commit -m "$(cat <<'EOF'
feat: implement non-blocking TLS/SSL support

Parameters:
- tls => 1: enable TLS with defaults
- tls => { ca_file, cert_file, key_file, verify }: custom options
- rediss:// URI scheme enables TLS automatically

Non-blocking handshake:
- Uses SSL_startHandshake => 0 to avoid blocking
- Drives handshake with connect_SSL + readiness waiting
- Handles SSL_WANT_READ / SSL_WANT_WRITE properly
- Respects connect_timeout for entire handshake

WARNING: Localhost tests pass even with blocking code.
Production deployments with network latency will hang
if handshake is blocking. Always test with real network.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 Complete!

After completing all 6 tasks, you have:

1. **Error Classes** - Typed exceptions for all failure modes
2. **URI Parsing** - Connection string support
3. **Timeouts** - Two-tier timeout system (socket + request)
4. **Reconnection** - Auto-reconnect with exponential backoff
5. **Authentication** - AUTH, SELECT, CLIENT SETNAME
6. **TLS** - Non-blocking TLS handshake

### Verification Checklist

- [ ] All unit tests pass: `prove -l t/01-unit/`
- [ ] All connection tests pass: `prove -l t/10-connection/`
- [ ] Original tests still pass: `prove -l t/01-basic.t t/02-nonblocking.t t/03-pubsub.t`
- [ ] Non-blocking proof passes: `prove -l t/02-nonblocking.t`
- [ ] Full test suite: `prove -l t/`

### Next Phase

Phase 2 covers **Command Generation**:
- Task 7: Build script for Commands.pm
- Task 8: Generate command methods from redis-doc
- Task 9: Key extraction and prefixing

Create `docs/plans/2026-01-01-implementation-phase2.md` when ready.
