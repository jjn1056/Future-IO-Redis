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

# Helper: await a Future and return its result (throws on failure)
sub await_f {
    my ($f) = @_;
    $loop->await($f);
    return $f->get;
}

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
        my $f = $redis->connect;
        $loop->await($f);
        eval { $f->get };
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

        await_f($redis->connect);
        my $pong = await_f($redis->ping);
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
        await_f($redis->connect);
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

        await_f($redis->connect);
        my $pong = await_f($redis->ping);
        is($pong, 'PONG', 'TLS + auth works');

        $redis->disconnect;
    };
}

done_testing;
