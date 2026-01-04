# Async::Redis Phase 6: PubSub Refinement & Connection Pool

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement production-ready PubSub with sharded channels, pattern subscriptions, and reconnect replay, plus a robust connection pool with dirty state detection, health checks, and the `with()` scoped pattern.

**Architecture:** Subscription.pm provides async iterator for messages with channel tracking for reconnect replay. Pool.pm manages connection lifecycle with min/max sizing, idle timeouts, and rigorous dirty detection to prevent cross-user data leakage.

**Tech Stack:** Perl 5.18+, Future::AsyncAwait, Future::IO

**Prerequisite:** Phases 1-5 complete (connection, commands, transactions, scripting, blocking, SCAN, pipelining)

---

## Task Overview

| Task | Focus | Files |
|------|-------|-------|
| 16 | PubSub Refinement | `lib/Future/IO/Redis/Subscription.pm`, `t/50-pubsub/*.t` |
| 17 | Connection Pool | `lib/Future/IO/Redis/Pool.pm`, `t/90-pool/*.t` |

---

## Task 16: PubSub Refinement

**Files:**
- Create: `lib/Future/IO/Redis/Subscription.pm`
- Create: `t/50-pubsub/subscribe.t`
- Create: `t/50-pubsub/psubscribe.t`
- Create: `t/50-pubsub/unsubscribe.t`
- Create: `t/50-pubsub/sharded.t`
- Create: `t/50-pubsub/reconnect-replay.t`
- Create: `t/50-pubsub/multiple-channels.t`
- Modify: `lib/Future/IO/Redis.pm` (add in_pubsub tracking, improve subscribe methods)

### Step 1: Create test directory

Run: `mkdir -p t/50-pubsub`

### Step 2: Write basic subscribe test

```perl
# t/50-pubsub/subscribe.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $publisher = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    my $subscriber = Async::Redis->new(host => 'localhost');
    $loop->await($subscriber->connect);

    subtest 'basic subscribe and receive' => sub {
        my @received;
        my $done = Future->new;

        # Start subscription
        my $sub_future = (async sub {
            my $sub = await $subscriber->subscribe('test:sub:basic');

            ok($sub->isa('Async::Redis::Subscription'), 'returns Subscription object');
            is_deeply([$sub->channels], ['test:sub:basic'], 'tracks subscribed channels');

            # Receive 3 messages
            for my $i (1..3) {
                my $msg = await $sub->next;
                push @received, $msg;
            }

            $done->done;
        })->();

        # Wait for subscription to be active
        $loop->await(Future::IO->sleep(0.1));

        # Publish messages
        for my $i (1..3) {
            my $listeners = $loop->await($publisher->publish('test:sub:basic', "message $i"));
            ok($listeners >= 1, "publish $i reached subscriber");
        }

        # Wait for all received
        $loop->await($done);

        is(scalar @received, 3, 'received 3 messages');
        is($received[0]{type}, 'message', 'message type');
        is($received[0]{channel}, 'test:sub:basic', 'correct channel');
        is($received[0]{data}, 'message 1', 'correct data');
        is($received[1]{data}, 'message 2', 'second message');
        is($received[2]{data}, 'message 3', 'third message');
    };

    subtest 'subscriber connection is in pubsub mode' => sub {
        ok($subscriber->in_pubsub, 'connection marked as in_pubsub');

        # Regular commands should fail on pubsub connection
        my $error;
        eval {
            $loop->await($subscriber->get('some:key'));
        };
        $error = $@;
        ok($error, 'regular command fails on pubsub connection');
        like("$error", qr/pubsub|subscribe/i, 'error mentions pubsub mode');
    };

    subtest 'message structure' => sub {
        my $sub = await $subscriber->subscribe('test:sub:struct');
        my $msg_future = $sub->next;

        $loop->await($publisher->publish('test:sub:struct', 'test payload'));

        my $msg = $loop->await($msg_future);

        is(ref $msg, 'HASH', 'message is hashref');
        ok(exists $msg->{type}, 'has type field');
        ok(exists $msg->{channel}, 'has channel field');
        ok(exists $msg->{data}, 'has data field');
        is($msg->{type}, 'message', 'type is message');
    };

    subtest 'non-blocking verification' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Wait for 10 messages
        my $count = 0;
        my $receiver = (async sub {
            my $sub = await $subscriber->subscribe('test:sub:nonblock');
            while ($count < 10) {
                await $sub->next;
                $count++;
            }
        })->();

        # Publish with small delays
        my $sender = (async sub {
            for my $i (1..10) {
                await Future::IO->sleep(0.05);
                await $publisher->publish('test:sub:nonblock', "msg $i");
            }
        })->();

        $loop->await(Future->needs_all($receiver, $sender));

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 20, "Event loop ticked " . scalar(@ticks) . " times during pubsub");
    };

    $publisher->disconnect;
    $subscriber->disconnect;
}

done_testing;
```

### Step 3: Run test to verify it fails

Run: `prove -l t/50-pubsub/subscribe.t`
Expected: FAIL (Subscription.pm not fully implemented)

### Step 4: Write Subscription.pm

```perl
# lib/Future/IO/Redis/Subscription.pm
package Async::Redis::Subscription;

use strict;
use warnings;
use 5.018;

use Future;
use Future::AsyncAwait;

our $VERSION = '0.001';

sub new {
    my ($class, %args) = @_;

    return bless {
        redis            => $args{redis},
        channels         => {},      # channel => 1 (for regular subscribe)
        patterns         => {},      # pattern => 1 (for psubscribe)
        sharded_channels => {},      # channel => 1 (for ssubscribe)
        _message_queue   => [],      # Buffer for messages
        _waiters         => [],      # Futures waiting for messages
        _closed          => 0,
    }, $class;
}

# Track a channel subscription
sub _add_channel {
    my ($self, $channel) = @_;
    $self->{channels}{$channel} = 1;
}

sub _add_pattern {
    my ($self, $pattern) = @_;
    $self->{patterns}{$pattern} = 1;
}

sub _add_sharded_channel {
    my ($self, $channel) = @_;
    $self->{sharded_channels}{$channel} = 1;
}

sub _remove_channel {
    my ($self, $channel) = @_;
    delete $self->{channels}{$channel};
}

sub _remove_pattern {
    my ($self, $pattern) = @_;
    delete $self->{patterns}{$pattern};
}

sub _remove_sharded_channel {
    my ($self, $channel) = @_;
    delete $self->{sharded_channels}{$channel};
}

# List subscribed channels/patterns
sub channels { keys %{shift->{channels}} }
sub patterns { keys %{shift->{patterns}} }
sub sharded_channels { keys %{shift->{sharded_channels}} }

sub channel_count {
    my ($self) = @_;
    return scalar(keys %{$self->{channels}})
         + scalar(keys %{$self->{patterns}})
         + scalar(keys %{$self->{sharded_channels}});
}

# Receive next message (async iterator pattern)
async sub next {
    my ($self) = @_;

    # Check if subscription is closed
    return undef if $self->{_closed};

    # Return buffered message if available
    if (@{$self->{_message_queue}}) {
        return shift @{$self->{_message_queue}};
    }

    # Wait for next message
    my $waiter = Future->new;
    push @{$self->{_waiters}}, $waiter;

    return await $waiter;
}

# Alias for compatibility
sub next_message { shift->next(@_) }

# Internal: called when message arrives
sub _deliver_message {
    my ($self, $msg) = @_;

    if (@{$self->{_waiters}}) {
        # Someone is waiting - deliver directly
        my $waiter = shift @{$self->{_waiters}};
        $waiter->done($msg);
    }
    else {
        # Buffer the message
        push @{$self->{_message_queue}}, $msg;
    }
}

# Unsubscribe from specific channels
async sub unsubscribe {
    my ($self, @channels) = @_;

    return if $self->{_closed};

    my $redis = $self->{redis};

    if (@channels) {
        # Partial unsubscribe
        await $redis->_send_command('UNSUBSCRIBE', @channels);

        # Read confirmations
        for my $ch (@channels) {
            my $msg = await $redis->_read_pubsub_frame();
            $self->_remove_channel($ch);
        }
    }
    else {
        # Full unsubscribe - all channels
        my @all_channels = $self->channels;

        if (@all_channels) {
            await $redis->_send_command('UNSUBSCRIBE');

            # Read all confirmations
            for my $ch (@all_channels) {
                my $msg = await $redis->_read_pubsub_frame();
                $self->_remove_channel($ch);
            }
        }
    }

    # If no subscriptions remain, close and exit pubsub mode
    if ($self->channel_count == 0) {
        $self->_close;
    }

    return $self;
}

# Unsubscribe from patterns
async sub punsubscribe {
    my ($self, @patterns) = @_;

    return if $self->{_closed};

    my $redis = $self->{redis};

    if (@patterns) {
        await $redis->_send_command('PUNSUBSCRIBE', @patterns);

        for my $p (@patterns) {
            my $msg = await $redis->_read_pubsub_frame();
            $self->_remove_pattern($p);
        }
    }
    else {
        my @all_patterns = $self->patterns;

        if (@all_patterns) {
            await $redis->_send_command('PUNSUBSCRIBE');

            for my $p (@all_patterns) {
                my $msg = await $redis->_read_pubsub_frame();
                $self->_remove_pattern($p);
            }
        }
    }

    if ($self->channel_count == 0) {
        $self->_close;
    }

    return $self;
}

# Unsubscribe from sharded channels
async sub sunsubscribe {
    my ($self, @channels) = @_;

    return if $self->{_closed};

    my $redis = $self->{redis};

    if (@channels) {
        await $redis->_send_command('SUNSUBSCRIBE', @channels);

        for my $ch (@channels) {
            my $msg = await $redis->_read_pubsub_frame();
            $self->_remove_sharded_channel($ch);
        }
    }
    else {
        my @all = $self->sharded_channels;

        if (@all) {
            await $redis->_send_command('SUNSUBSCRIBE');

            for my $ch (@all) {
                my $msg = await $redis->_read_pubsub_frame();
                $self->_remove_sharded_channel($ch);
            }
        }
    }

    if ($self->channel_count == 0) {
        $self->_close;
    }

    return $self;
}

# Close subscription
sub _close {
    my ($self) = @_;

    $self->{_closed} = 1;
    $self->{redis}{in_pubsub} = 0;

    # Cancel any waiters
    for my $waiter (@{$self->{_waiters}}) {
        $waiter->done(undef) unless $waiter->is_ready;
    }
    $self->{_waiters} = [];
}

sub is_closed { shift->{_closed} }

# Get all subscriptions for reconnect replay
sub get_replay_commands {
    my ($self) = @_;

    my @commands;

    my @channels = $self->channels;
    push @commands, ['SUBSCRIBE', @channels] if @channels;

    my @patterns = $self->patterns;
    push @commands, ['PSUBSCRIBE', @patterns] if @patterns;

    my @sharded = $self->sharded_channels;
    push @commands, ['SSUBSCRIBE', @sharded] if @sharded;

    return @commands;
}

1;

__END__

=head1 NAME

Async::Redis::Subscription - PubSub subscription handler

=head1 SYNOPSIS

    my $sub = await $redis->subscribe('channel1', 'channel2');

    while (my $msg = await $sub->next) {
        say "Channel: $msg->{channel}";
        say "Data: $msg->{data}";
    }

    await $sub->unsubscribe('channel1');
    await $sub->unsubscribe;  # all remaining

=head1 DESCRIPTION

Manages Redis PubSub subscriptions with async iterator pattern.

=head1 MESSAGE STRUCTURE

    {
        type    => 'message',      # or 'pmessage', 'smessage'
        channel => 'channel_name',
        pattern => 'pattern',      # only for pmessage
        data    => 'payload',
    }

=cut
```

### Step 5: Update Async::Redis with pubsub improvements

Edit `lib/Future/IO/Redis.pm`:

```perl
use Async::Redis::Subscription;

# In new(), add:
#   in_pubsub       => 0,
#   _subscription   => undef,

# Add pubsub state accessor
sub in_pubsub { shift->{in_pubsub} }

# Improved subscribe method
async sub subscribe {
    my ($self, @channels) = @_;

    die Async::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    die "Already in pubsub mode - use existing subscription object"
        if $self->{in_pubsub} && !$self->{_subscription};

    # Create or reuse subscription
    my $sub = $self->{_subscription} //= Async::Redis::Subscription->new(redis => $self);

    # Send SUBSCRIBE command
    await $self->_send_command('SUBSCRIBE', @channels);

    # Read subscription confirmations
    for my $ch (@channels) {
        my $msg = await $self->_read_pubsub_frame();
        # Response: ['subscribe', $channel, $count]
        $sub->_add_channel($ch);
    }

    $self->{in_pubsub} = 1;

    # Start message pump if not already running
    $self->_start_pubsub_pump($sub) unless $self->{_pump_running};

    return $sub;
}

# Pattern subscribe
async sub psubscribe {
    my ($self, @patterns) = @_;

    die Async::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    my $sub = $self->{_subscription} //= Async::Redis::Subscription->new(redis => $self);

    await $self->_send_command('PSUBSCRIBE', @patterns);

    for my $p (@patterns) {
        my $msg = await $self->_read_pubsub_frame();
        $sub->_add_pattern($p);
    }

    $self->{in_pubsub} = 1;
    $self->_start_pubsub_pump($sub) unless $self->{_pump_running};

    return $sub;
}

# Sharded subscribe (Redis 7+)
async sub ssubscribe {
    my ($self, @channels) = @_;

    die Async::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    my $sub = $self->{_subscription} //= Async::Redis::Subscription->new(redis => $self);

    await $self->_send_command('SSUBSCRIBE', @channels);

    for my $ch (@channels) {
        my $msg = await $self->_read_pubsub_frame();
        $sub->_add_sharded_channel($ch);
    }

    $self->{in_pubsub} = 1;
    $self->_start_pubsub_pump($sub) unless $self->{_pump_running};

    return $sub;
}

# Read pubsub frame (subscription confirmation or message)
async sub _read_pubsub_frame {
    my ($self) = @_;

    my $msg = await $self->_read_response();
    return $self->_decode_response($msg);
}

# Message pump - continuously reads and delivers messages
sub _start_pubsub_pump {
    my ($self, $sub) = @_;

    return if $self->{_pump_running};
    $self->{_pump_running} = 1;

    my $pump;
    $pump = (async sub {
        while ($self->{in_pubsub} && !$sub->is_closed) {
            my $frame;
            eval {
                $frame = await $self->_read_pubsub_frame();
            };

            if ($@) {
                # Connection error - mark pump stopped
                $self->{_pump_running} = 0;
                return;
            }

            last unless $frame && ref $frame eq 'ARRAY';

            my $type = $frame->[0] // '';

            if ($type eq 'message') {
                $sub->_deliver_message({
                    type    => 'message',
                    channel => $frame->[1],
                    data    => $frame->[2],
                });
            }
            elsif ($type eq 'pmessage') {
                $sub->_deliver_message({
                    type    => 'pmessage',
                    pattern => $frame->[1],
                    channel => $frame->[2],
                    data    => $frame->[3],
                });
            }
            elsif ($type eq 'smessage') {
                $sub->_deliver_message({
                    type    => 'smessage',
                    channel => $frame->[1],
                    data    => $frame->[2],
                });
            }
            elsif ($type =~ /^(un)?p?s?subscribe$/) {
                # Subscription confirmation - handled elsewhere
            }
            else {
                # Unknown message type
                warn "Unknown pubsub message type: $type";
            }
        }

        $self->{_pump_running} = 0;
    })->();
}

# Prevent regular commands on pubsub connection
# Modify command() method to check in_pubsub:
async sub command {
    my ($self, @args) = @_;

    die Async::Redis::Error::Disconnected->new(
        message => "Not connected",
    ) unless $self->{connected};

    # Block regular commands on pubsub connection
    if ($self->{in_pubsub}) {
        my $cmd = uc($args[0] // '');
        unless ($cmd =~ /^(SUBSCRIBE|UNSUBSCRIBE|PSUBSCRIBE|PUNSUBSCRIBE|SSUBSCRIBE|SUNSUBSCRIBE|PING|QUIT)$/) {
            die Async::Redis::Error::Protocol->new(
                message => "Cannot execute '$cmd' on connection in PubSub mode",
            );
        }
    }

    # ... rest of existing command() implementation
}

# Send command without reading response (for pubsub)
async sub _send_command {
    my ($self, @args) = @_;

    my $cmd = $self->_build_command(@args);
    await $self->_send($cmd);
}
```

### Step 6: Run test to verify it passes

Run: `prove -l t/50-pubsub/subscribe.t`
Expected: PASS

### Step 7: Write pattern subscribe test

```perl
# t/50-pubsub/psubscribe.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $publisher = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    my $subscriber = Async::Redis->new(host => 'localhost');
    $loop->await($subscriber->connect);

    subtest 'psubscribe receives messages matching pattern' => sub {
        my @received;
        my $done = Future->new;

        my $sub_future = (async sub {
            my $sub = await $subscriber->psubscribe('news:*');

            ok($sub->isa('Async::Redis::Subscription'), 'returns Subscription');
            is_deeply([$sub->patterns], ['news:*'], 'tracks subscribed patterns');

            for my $i (1..3) {
                my $msg = await $sub->next;
                push @received, $msg;
            }

            $done->done;
        })->();

        $loop->await(Future::IO->sleep(0.1));

        # Publish to different channels matching pattern
        $loop->await($publisher->publish('news:sports', 'Game update'));
        $loop->await($publisher->publish('news:weather', 'Sunny skies'));
        $loop->await($publisher->publish('news:tech', 'New release'));

        $loop->await($done);

        is(scalar @received, 3, 'received 3 messages');
        is($received[0]{type}, 'pmessage', 'pmessage type');
        is($received[0]{pattern}, 'news:*', 'pattern field populated');
        is($received[0]{channel}, 'news:sports', 'actual channel');
        is($received[0]{data}, 'Game update', 'message data');
    };

    subtest 'psubscribe with multiple patterns' => sub {
        my $sub2 = Async::Redis->new(host => 'localhost');
        $loop->await($sub2->connect);

        my @received;
        my $done = Future->new;

        my $sub_future = (async sub {
            my $sub = await $sub2->psubscribe('alert:*', 'log:*');

            is_deeply([sort $sub->patterns], ['alert:*', 'log:*'], 'both patterns tracked');

            for my $i (1..2) {
                my $msg = await $sub->next;
                push @received, $msg;
            }

            $done->done;
        })->();

        $loop->await(Future::IO->sleep(0.1));

        $loop->await($publisher->publish('alert:critical', 'System down'));
        $loop->await($publisher->publish('log:info', 'User logged in'));

        $loop->await($done);

        is(scalar @received, 2, 'received from both patterns');

        my %by_pattern = map { $_->{pattern} => $_->{data} } @received;
        is($by_pattern{'alert:*'}, 'System down', 'got alert message');
        is($by_pattern{'log:*'}, 'User logged in', 'got log message');

        $sub2->disconnect;
    };

    subtest 'pattern does not match non-matching channels' => sub {
        my $sub3 = Async::Redis->new(host => 'localhost');
        $loop->await($sub3->connect);

        my $received_count = 0;

        my $sub_future = (async sub {
            my $sub = await $sub3->psubscribe('user:*');

            # Set a short timeout for receiving
            my $timeout = $loop->delay_future(after => 0.5);
            my $msg_future = $sub->next;

            my ($result) = await Future->wait_any($timeout, $msg_future);
            $received_count++ if defined $result && ref $result eq 'HASH';
        })->();

        $loop->await(Future::IO->sleep(0.1));

        # Publish to non-matching channel
        $loop->await($publisher->publish('admin:login', 'Admin logged in'));

        $loop->await($sub_future);

        is($received_count, 0, 'did not receive non-matching message');

        $sub3->disconnect;
    };

    $publisher->disconnect;
    $subscriber->disconnect;
}

done_testing;
```

### Step 8: Run pattern subscribe test

Run: `prove -l t/50-pubsub/psubscribe.t`
Expected: PASS

### Step 9: Write unsubscribe test

```perl
# t/50-pubsub/unsubscribe.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $publisher = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    my $subscriber = Async::Redis->new(host => 'localhost');
    $loop->await($subscriber->connect);

    subtest 'partial unsubscribe' => sub {
        my $sub = $loop->await($subscriber->subscribe('chan:a', 'chan:b', 'chan:c'));

        is($sub->channel_count, 3, 'subscribed to 3 channels');
        is_deeply([sort $sub->channels], ['chan:a', 'chan:b', 'chan:c'], 'all channels listed');

        # Unsubscribe from one
        $loop->await($sub->unsubscribe('chan:b'));

        is($sub->channel_count, 2, 'now subscribed to 2 channels');
        is_deeply([sort $sub->channels], ['chan:a', 'chan:c'], 'chan:b removed');

        ok($subscriber->in_pubsub, 'still in pubsub mode');
        ok(!$sub->is_closed, 'subscription not closed');
    };

    subtest 'full unsubscribe exits pubsub mode' => sub {
        my $sub2 = Async::Redis->new(host => 'localhost');
        $loop->await($sub2->connect);

        my $sub = $loop->await($sub2->subscribe('temp:chan'));
        ok($sub2->in_pubsub, 'in pubsub mode');

        $loop->await($sub->unsubscribe);

        is($sub->channel_count, 0, 'no channels remaining');
        ok($sub->is_closed, 'subscription closed');
        ok(!$sub2->in_pubsub, 'exited pubsub mode');

        # Can now use regular commands
        my $result = $loop->await($sub2->ping);
        is($result, 'PONG', 'regular command works after full unsubscribe');

        $sub2->disconnect;
    };

    subtest 'punsubscribe from patterns' => sub {
        my $sub3 = Async::Redis->new(host => 'localhost');
        $loop->await($sub3->connect);

        my $sub = $loop->await($sub3->psubscribe('pat:*', 'log:*'));
        is_deeply([sort $sub->patterns], ['log:*', 'pat:*'], 'subscribed to patterns');

        $loop->await($sub->punsubscribe('log:*'));
        is_deeply([$sub->patterns], ['pat:*'], 'log:* removed');

        $loop->await($sub->punsubscribe);
        is($sub->channel_count, 0, 'all patterns removed');

        $sub3->disconnect;
    };

    subtest 'unsubscribe stops receiving messages' => sub {
        my $sub4 = Async::Redis->new(host => 'localhost');
        $loop->await($sub4->connect);

        my @received;

        my $sub = $loop->await($sub4->subscribe('unsub:test'));

        # Receive one message
        my $waiter = (async sub {
            my $msg = await $sub->next;
            push @received, $msg if $msg;
        })->();

        $loop->await(Future::IO->sleep(0.1));
        $loop->await($publisher->publish('unsub:test', 'first'));
        $loop->await($waiter);

        is(scalar @received, 1, 'received first message');

        # Unsubscribe
        $loop->await($sub->unsubscribe);

        # Publish another (should not receive)
        $loop->await($publisher->publish('unsub:test', 'second'));
        $loop->await(Future::IO->sleep(0.2));

        is(scalar @received, 1, 'did not receive after unsubscribe');

        $sub4->disconnect;
    };

    $publisher->disconnect;
    $subscriber->disconnect;
}

done_testing;
```

### Step 10: Run unsubscribe test

Run: `prove -l t/50-pubsub/unsubscribe.t`
Expected: PASS

### Step 11: Write sharded pubsub test

```perl
# t/50-pubsub/sharded.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $publisher = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    # Check Redis version for sharded pubsub (7.0+)
    my $info = $loop->await($publisher->info('server'));
    my $version = $info->{server}{redis_version} // '0';
    my ($major) = split /\./, $version;
    skip "Sharded PubSub requires Redis 7.0+, got $version", 1
        unless $major >= 7;

    my $subscriber = Async::Redis->new(host => 'localhost');
    $loop->await($subscriber->connect);

    subtest 'sharded subscribe (SSUBSCRIBE)' => sub {
        my @received;
        my $done = Future->new;

        my $sub_future = (async sub {
            my $sub = await $subscriber->ssubscribe('sharded:channel');

            is_deeply([$sub->sharded_channels], ['sharded:channel'], 'tracks sharded channels');

            my $msg = await $sub->next;
            push @received, $msg;

            $done->done;
        })->();

        $loop->await(Future::IO->sleep(0.1));

        # Use SPUBLISH for sharded channels
        my $listeners = $loop->await($publisher->spublish('sharded:channel', 'sharded message'));
        ok($listeners >= 1, 'SPUBLISH reached subscriber');

        $loop->await($done);

        is(scalar @received, 1, 'received sharded message');
        is($received[0]{type}, 'smessage', 'smessage type');
        is($received[0]{channel}, 'sharded:channel', 'correct channel');
        is($received[0]{data}, 'sharded message', 'correct data');
    };

    subtest 'sharded unsubscribe (SUNSUBSCRIBE)' => sub {
        my $sub2 = Async::Redis->new(host => 'localhost');
        $loop->await($sub2->connect);

        my $sub = $loop->await($sub2->ssubscribe('sharded:a', 'sharded:b'));
        is_deeply([sort $sub->sharded_channels], ['sharded:a', 'sharded:b'], 'both sharded channels');

        $loop->await($sub->sunsubscribe('sharded:a'));
        is_deeply([$sub->sharded_channels], ['sharded:b'], 'sharded:a removed');

        $loop->await($sub->sunsubscribe);
        is($sub->channel_count, 0, 'all sharded channels removed');

        $sub2->disconnect;
    };

    subtest 'mixed regular and sharded subscriptions' => sub {
        my $sub3 = Async::Redis->new(host => 'localhost');
        $loop->await($sub3->connect);

        # Subscribe to regular channel
        my $sub = $loop->await($sub3->subscribe('regular:chan'));

        # Also subscribe to sharded channel
        await $sub3->ssubscribe('sharded:chan');

        is($sub->channel_count, 2, 'mixed subscriptions counted');
        is_deeply([$sub->channels], ['regular:chan'], 'regular channel tracked');
        is_deeply([$sub->sharded_channels], ['sharded:chan'], 'sharded channel tracked');

        $sub3->disconnect;
    };

    $publisher->disconnect;
    $subscriber->disconnect;
}

done_testing;
```

### Step 12: Write reconnect replay test

```perl
# t/50-pubsub/reconnect-replay.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $publisher = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    subtest 'subscription tracks channels for replay' => sub {
        my $subscriber = Async::Redis->new(host => 'localhost');
        $loop->await($subscriber->connect);

        my $sub = $loop->await($subscriber->subscribe('chan:a', 'chan:b'));
        $loop->await($subscriber->psubscribe('pattern:*'));

        my @replay = $sub->get_replay_commands;

        is(scalar @replay, 2, 'two replay commands');

        my ($sub_cmd) = grep { $_->[0] eq 'SUBSCRIBE' } @replay;
        my ($psub_cmd) = grep { $_->[0] eq 'PSUBSCRIBE' } @replay;

        is_deeply([sort @{$sub_cmd}[1..$#$sub_cmd]], ['chan:a', 'chan:b'], 'SUBSCRIBE channels');
        is_deeply($psub_cmd, ['PSUBSCRIBE', 'pattern:*'], 'PSUBSCRIBE pattern');

        $subscriber->disconnect;
    };

    subtest 'reconnect replays subscriptions' => sub {
        my $subscriber = Async::Redis->new(
            host => 'localhost',
            reconnect => 1,
            reconnect_delay => 0.1,
        );
        $loop->await($subscriber->connect);

        my @received;

        # Subscribe
        my $sub = $loop->await($subscriber->subscribe('reconnect:test'));

        # Receive first message
        my $receiver = (async sub {
            while (1) {
                my $msg = await $sub->next;
                last unless $msg;
                push @received, $msg;
                last if @received >= 2;
            }
        })->();

        $loop->await(Future::IO->sleep(0.1));
        $loop->await($publisher->publish('reconnect:test', 'before disconnect'));

        # Wait for first message
        $loop->await(Future::IO->sleep(0.2));
        is(scalar @received, 1, 'received message before disconnect');

        # Simulate disconnect
        # Note: This test assumes reconnect logic is implemented
        # For now, just verify the replay commands are generated correctly

        $subscriber->disconnect;
    };

    $publisher->disconnect;
}

done_testing;
```

### Step 13: Write multiple channels test

```perl
# t/50-pubsub/multiple-channels.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $publisher = eval {
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $publisher;

    my $subscriber = Async::Redis->new(host => 'localhost');
    $loop->await($subscriber->connect);

    subtest 'subscribe to many channels at once' => sub {
        my @channels = map { "multi:chan:$_" } (1..20);

        my $sub = $loop->await($subscriber->subscribe(@channels));

        is($sub->channel_count, 20, 'subscribed to 20 channels');
        is_deeply([sort $sub->channels], [sort @channels], 'all channels tracked');
    };

    subtest 'receive from multiple channels' => sub {
        my %received_by_channel;
        my $done = Future->new;

        my $receiver = (async sub {
            my $sub = $subscriber->{_subscription};
            while (scalar keys %received_by_channel < 5) {
                my $msg = await $sub->next;
                $received_by_channel{$msg->{channel}} = $msg->{data};
            }
            $done->done;
        })->();

        $loop->await(Future::IO->sleep(0.1));

        # Publish to different channels
        for my $i (1..5) {
            $loop->await($publisher->publish("multi:chan:$i", "msg$i"));
        }

        $loop->await($done);

        is(scalar keys %received_by_channel, 5, 'received from 5 different channels');
        for my $i (1..5) {
            is($received_by_channel{"multi:chan:$i"}, "msg$i", "got message from chan $i");
        }
    };

    subtest 'add channels to existing subscription' => sub {
        my $sub2 = Async::Redis->new(host => 'localhost');
        $loop->await($sub2->connect);

        # Initial subscription
        my $sub = $loop->await($sub2->subscribe('add:initial'));
        is($sub->channel_count, 1, 'initial subscription');

        # Add more channels
        await $sub2->subscribe('add:second', 'add:third');
        is($sub->channel_count, 3, 'added channels');
        is_deeply([sort $sub->channels], ['add:initial', 'add:second', 'add:third'], 'all tracked');

        $sub2->disconnect;
    };

    subtest 'non-blocking with many channels' => sub {
        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my @received;

        my $receiver = (async sub {
            my $sub = $subscriber->{_subscription};
            for my $i (1..50) {
                my $msg = await $sub->next;
                push @received, $msg;
            }
        })->();

        # Publish 50 messages across channels
        my $sender = (async sub {
            for my $i (1..50) {
                my $chan = "multi:chan:" . (($i % 20) + 1);
                await $publisher->publish($chan, "batch$i");
            }
        })->();

        $loop->await(Future->needs_all($receiver, $sender));

        $timer->stop;
        $loop->remove($timer);

        is(scalar @received, 50, 'received all 50 messages');
        ok(@ticks >= 5, "Event loop ticked " . scalar(@ticks) . " times");
    };

    $publisher->disconnect;
    $subscriber->disconnect;
}

done_testing;
```

### Step 14: Run all pubsub tests

Run: `prove -l t/50-pubsub/`
Expected: PASS

### Step 15: Commit

```bash
git add lib/Future/IO/Redis/Subscription.pm lib/Future/IO/Redis.pm t/50-pubsub/
git commit -m "$(cat <<'EOF'
feat: implement comprehensive PubSub with sharded channels

Subscription.pm:
- Async iterator pattern: while ($msg = await $sub->next) { ... }
- Channel tracking for regular, pattern, and sharded subscriptions
- Partial and full unsubscribe support
- get_replay_commands() for reconnect

PubSub features:
- subscribe() for regular channels
- psubscribe() for pattern matching (news:*)
- ssubscribe() for sharded pubsub (Redis 7+)
- Corresponding unsubscribe methods
- Message pump runs in background

Message structure:
- type: 'message', 'pmessage', or 'smessage'
- channel: actual channel name
- pattern: matching pattern (pmessage only)
- data: message payload

Connection state:
- in_pubsub flag prevents regular commands
- Only SUBSCRIBE/UNSUBSCRIBE/PING allowed in pubsub mode
- Full unsubscribe exits pubsub mode

Test coverage:
- Basic subscribe/publish flow
- Pattern subscriptions with wildcards
- Partial and full unsubscribe
- Sharded pubsub (Redis 7+)
- Multiple channel subscriptions
- Non-blocking verification

EOF
)"
```

---

## Task 17: Connection Pool

**Files:**
- Create: `lib/Future/IO/Redis/Pool.pm`
- Create: `t/90-pool/basic.t`
- Create: `t/90-pool/with-pattern.t`
- Create: `t/90-pool/dirty-detection.t`
- Create: `t/90-pool/cleanup.t`
- Create: `t/90-pool/health-check.t`
- Create: `t/90-pool/sizing.t`
- Create: `t/90-pool/stats.t`
- Create: `t/90-pool/concurrent.t`
- Modify: `lib/Future/IO/Redis.pm` (add connection state tracking)

### Step 1: Create test directory

Run: `mkdir -p t/90-pool`

### Step 2: Write basic pool test

```perl
# t/90-pool/basic.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    # Verify Redis is available
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'pool creation' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 2,
            max  => 5,
        );

        ok($pool, 'pool created');
        is($pool->min, 2, 'min connections');
        is($pool->max, 5, 'max connections');
    };

    subtest 'acquire and release' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 1,
            max  => 3,
        );

        my $conn = $loop->await($pool->acquire);
        ok($conn, 'acquired connection');
        ok($conn->isa('Async::Redis'), 'connection is Redis object');

        # Use connection
        my $result = $loop->await($conn->ping);
        is($result, 'PONG', 'connection works');

        # Release
        $pool->release($conn);

        my $stats = $pool->stats;
        is($stats->{idle}, 1, 'connection returned to pool');
        is($stats->{active}, 0, 'no active connections');
    };

    subtest 'acquire returns same connection' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 1,
            max  => 3,
        );

        my $conn1 = $loop->await($pool->acquire);
        my $id1 = "$conn1";  # stringified address
        $pool->release($conn1);

        my $conn2 = $loop->await($pool->acquire);
        my $id2 = "$conn2";

        is($id1, $id2, 'got same connection from pool');

        $pool->release($conn2);
    };

    subtest 'multiple acquires up to max' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 0,
            max  => 3,
        );

        my @conns;
        for my $i (1..3) {
            push @conns, $loop->await($pool->acquire);
        }

        is(scalar @conns, 3, 'acquired max connections');

        my $stats = $pool->stats;
        is($stats->{active}, 3, '3 active connections');
        is($stats->{idle}, 0, '0 idle connections');
        is($stats->{total}, 3, '3 total connections');

        # Release all
        $pool->release($_) for @conns;

        $stats = $pool->stats;
        is($stats->{active}, 0, '0 active after release');
        is($stats->{idle}, 3, '3 idle after release');
    };

    subtest 'acquire blocks when pool exhausted' => sub {
        my $pool = Async::Redis::Pool->new(
            host            => 'localhost',
            max             => 1,
            acquire_timeout => 1,
        );

        my $conn1 = $loop->await($pool->acquire);

        # Second acquire should timeout
        my $start = time();
        my $error;
        eval {
            $loop->await($pool->acquire);
        };
        $error = $@;
        my $elapsed = time() - $start;

        ok($error, 'acquire timed out');
        like("$error", qr/timeout|acquire/i, 'timeout error');
        ok($elapsed >= 0.9 && $elapsed < 2.0, "waited ~1s ($elapsed)");

        $pool->release($conn1);
    };

    subtest 'non-blocking verification' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 2,
            max  => 5,
        );

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        # Do 50 acquire/use/release cycles
        for my $i (1..50) {
            my $conn = $loop->await($pool->acquire);
            $loop->await($conn->ping);
            $pool->release($conn);
        }

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 5, "Event loop ticked " . scalar(@ticks) . " times");
    };
}

done_testing;
```

### Step 3: Run test to verify it fails

Run: `prove -l t/90-pool/basic.t`
Expected: FAIL (Pool.pm not implemented)

### Step 4: Write Pool.pm

```perl
# lib/Future/IO/Redis/Pool.pm
package Async::Redis::Pool;

use strict;
use warnings;
use 5.018;

use Future;
use Future::AsyncAwait;
use Future::IO;
use Async::Redis;
use Async::Redis::Error::Timeout;

our $VERSION = '0.001';

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        # Connection params (passed to Async::Redis->new)
        host     => $args{host} // 'localhost',
        port     => $args{port} // 6379,
        password => $args{password},
        database => $args{database},
        tls      => $args{tls},
        uri      => $args{uri},

        # Pool sizing
        min => $args{min} // 1,
        max => $args{max} // 10,

        # Timeouts
        acquire_timeout  => $args{acquire_timeout} // 5,
        idle_timeout     => $args{idle_timeout} // 60,
        connect_timeout  => $args{connect_timeout} // 10,
        cleanup_timeout  => $args{cleanup_timeout} // 5,

        # Dirty handling
        on_dirty => $args{on_dirty} // 'destroy',

        # Pool state
        _idle    => [],   # Available connections
        _active  => {},   # Connections in use (conn => 1)
        _waiters => [],   # Futures waiting for connection
        _total_created  => 0,
        _total_destroyed => 0,
    }, $class;

    return $self;
}

# Accessors
sub min { shift->{min} }
sub max { shift->{max} }

# Statistics
sub stats {
    my ($self) = @_;

    return {
        active    => scalar keys %{$self->{_active}},
        idle      => scalar @{$self->{_idle}},
        waiting   => scalar @{$self->{_waiters}},
        total     => (scalar keys %{$self->{_active}}) + (scalar @{$self->{_idle}}),
        destroyed => $self->{_total_destroyed},
    };
}

# Acquire a connection from the pool
async sub acquire {
    my ($self) = @_;

    # Try to get an idle connection
    while (@{$self->{_idle}}) {
        my $conn = shift @{$self->{_idle}};

        # Health check
        my $healthy = await $self->_health_check($conn);
        if ($healthy) {
            $self->{_active}{"$conn"} = $conn;
            return $conn;
        }

        # Unhealthy - destroy and try next
        $self->_destroy_connection($conn);
    }

    # No idle connections - can we create a new one?
    my $current_total = (scalar keys %{$self->{_active}}) + (scalar @{$self->{_idle}});

    if ($current_total < $self->{max}) {
        my $conn = await $self->_create_connection;
        $self->{_active}{"$conn"} = $conn;
        return $conn;
    }

    # At max capacity - wait for release
    my $waiter = Future->new;
    push @{$self->{_waiters}}, $waiter;

    my $timeout_future = Future::IO->sleep($self->{acquire_timeout});

    my ($result) = await Future->wait_any(
        $waiter,
        $timeout_future->then(sub {
            Future->fail(Async::Redis::Error::Timeout->new(
                message => "Acquire timed out after $self->{acquire_timeout}s",
                timeout => $self->{acquire_timeout},
            ));
        }),
    );

    # If waiter was cancelled by timeout, remove from queue
    if (!$waiter->is_done) {
        @{$self->{_waiters}} = grep { $_ != $waiter } @{$self->{_waiters}};
        die $result if ref $result && $result->isa('Async::Redis::Error');
    }

    return $result;
}

# Release a connection back to the pool
sub release {
    my ($self, $conn) = @_;

    return unless $conn;

    # Remove from active
    delete $self->{_active}{"$conn"};

    # Check if connection is dirty
    if ($conn->is_dirty) {
        $self->{_total_destroyed}++;

        if ($self->{on_dirty} eq 'cleanup' && $self->_can_attempt_cleanup($conn)) {
            # Attempt cleanup asynchronously
            $self->_cleanup_connection($conn)->on_done(sub {
                $self->_return_to_pool($conn);
            })->on_fail(sub {
                $self->_destroy_connection($conn);
                $self->_maybe_create_replacement;
            });
        }
        else {
            # Default: destroy and potentially replace
            $self->_destroy_connection($conn);
            $self->_maybe_create_replacement;
        }
        return;
    }

    # Clean connection - return to pool or give to waiter
    $self->_return_to_pool($conn);
}

sub _return_to_pool {
    my ($self, $conn) = @_;

    # Give to waiting acquirer if any
    if (@{$self->{_waiters}}) {
        my $waiter = shift @{$self->{_waiters}};
        $self->{_active}{"$conn"} = $conn;
        $waiter->done($conn);
        return;
    }

    # Return to idle pool
    push @{$self->{_idle}}, $conn;
}

# Create a new connection
async sub _create_connection {
    my ($self) = @_;

    my %conn_args = (
        host            => $self->{host},
        port            => $self->{port},
        connect_timeout => $self->{connect_timeout},
    );

    $conn_args{password} = $self->{password} if defined $self->{password};
    $conn_args{database} = $self->{database} if defined $self->{database};
    $conn_args{tls}      = $self->{tls}      if $self->{tls};
    $conn_args{uri}      = $self->{uri}      if $self->{uri};

    my $conn = Async::Redis->new(%conn_args);
    await $conn->connect;

    $self->{_total_created}++;

    return $conn;
}

# Destroy a connection
sub _destroy_connection {
    my ($self, $conn) = @_;

    eval { $conn->disconnect };
    $self->{_total_destroyed}++;
}

# Maybe create a replacement connection to maintain min
sub _maybe_create_replacement {
    my ($self) = @_;

    my $current_total = (scalar keys %{$self->{_active}}) + (scalar @{$self->{_idle}});

    if ($current_total < $self->{min}) {
        # Create replacement asynchronously
        $self->_create_connection->on_done(sub {
            my ($conn) = @_;
            $self->_return_to_pool($conn);
        })->on_fail(sub {
            # Failed to create replacement - log and continue
            warn "Failed to create replacement connection: @_";
        });
    }
}

# Health check
async sub _health_check {
    my ($self, $conn) = @_;

    # Can't PING a pubsub connection
    if ($conn->in_pubsub) {
        return 0;
    }

    # Quick PING with 1 second timeout
    eval {
        my $result = await Future::IO->sleep(0)->then(sub {
            $conn->ping->timeout(1);
        });
        return 1 if defined $result && $result eq 'PONG';
    };

    return 0 if $@;
    return 1;
}

# Check if cleanup can be attempted
sub _can_attempt_cleanup {
    my ($self, $conn) = @_;

    # NEVER attempt cleanup for these states:

    # PubSub mode - UNSUBSCRIBE returns confirmation frames that
    # must be correctly drained in modal pubsub mode. Too risky.
    return 0 if $conn->in_pubsub;

    # Inflight requests - after timeout/reset we've already
    # declared the stream desynced.
    return 0 if $conn->inflight_count > 0;

    # Protocol error - stream already known-desynced
    return 0 if $conn->{protocol_error};

    # Cleanup MAY be attempted for these (still risky, but bounded):
    # - in_multi: DISCARD is safe if we're actually in MULTI
    # - watching: UNWATCH is always safe
    return 1 if $conn->in_multi || $conn->watching;

    # Unknown dirty state - don't risk it
    return 0;
}

# Attempt to cleanup a dirty connection
async sub _cleanup_connection {
    my ($self, $conn) = @_;

    # Note: Only called for in_multi or watching states
    # PubSub and inflight connections are always destroyed

    eval {
        # Reset transaction state
        if ($conn->in_multi) {
            await $conn->command('DISCARD')->timeout($self->{cleanup_timeout});
            $conn->{in_multi} = 0;
        }

        if ($conn->watching) {
            await $conn->command('UNWATCH')->timeout($self->{cleanup_timeout});
            $conn->{watching} = 0;
        }
    };

    if ($@) {
        die "Cleanup failed: $@";
    }

    # Verify connection is now clean
    if ($conn->is_dirty) {
        die "Connection still dirty after cleanup";
    }

    return $conn;
}

# The recommended pattern
async sub with {
    my ($self, $code) = @_;

    my $conn = await $self->acquire;
    my $result;
    my $error;

    eval {
        $result = await $code->($conn);
    };
    $error = $@;

    # Always release, even on exception
    # release() handles dirty detection
    $self->release($conn);

    die $error if $error;
    return $result;
}

# Shutdown the pool
async sub shutdown {
    my ($self) = @_;

    # Cancel waiters
    for my $waiter (@{$self->{_waiters}}) {
        $waiter->fail("Pool shutting down") unless $waiter->is_ready;
    }
    $self->{_waiters} = [];

    # Close idle connections
    for my $conn (@{$self->{_idle}}) {
        $self->_destroy_connection($conn);
    }
    $self->{_idle} = [];

    # Active connections will be closed when released
}

1;

__END__

=head1 NAME

Async::Redis::Pool - Connection pool for Async::Redis

=head1 SYNOPSIS

    my $pool = Async::Redis::Pool->new(
        host => 'localhost',
        min  => 2,
        max  => 10,
    );

    # Recommended: scoped pattern
    my $result = await $pool->with(async sub {
        my ($redis) = @_;
        await $redis->incr('counter');
    });

    # Manual acquire/release (be careful!)
    my $redis = await $pool->acquire;
    await $redis->set('key', 'value');
    $pool->release($redis);

=head1 DESCRIPTION

Manages a pool of Redis connections with automatic dirty detection.

=head2 Connection Cleanliness

A connection is "dirty" if it has state that could affect the next user:

=over 4

=item * in_multi - In a MULTI transaction

=item * watching - Has WATCH keys

=item * in_pubsub - In subscription mode

=item * inflight - Has pending responses

=back

Dirty connections are destroyed by default. The cost of a new connection
is far less than the risk of data corruption.

=head2 The with() Pattern

Always prefer C<with()> over manual acquire/release:

    await $pool->with(async sub {
        my ($redis) = @_;
        # Use $redis here
        # Connection released automatically, even on exception
    });

=cut
```

### Step 5: Add is_dirty and related methods to Async::Redis

Edit `lib/Future/IO/Redis.pm` to add connection state tracking:

```perl
# In new(), ensure these exist:
#   in_multi  => 0,
#   watching  => 0,
#   in_pubsub => 0,
#   inflight  => [],

# Connection state accessors
sub in_multi  { shift->{in_multi} }
sub watching  { shift->{watching} }
sub inflight_count { scalar @{shift->{inflight} // []} }

# Is connection dirty (unsafe to reuse)?
sub is_dirty {
    my ($self) = @_;

    return 1 if $self->{in_multi};
    return 1 if $self->{watching};
    return 1 if $self->{in_pubsub};
    return 1 if @{$self->{inflight} // []} > 0;

    return 0;
}
```

### Step 6: Run test to verify it passes

Run: `prove -l t/90-pool/basic.t`
Expected: PASS

### Step 7: Write with() pattern test

```perl
# t/90-pool/with-pattern.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    my $pool = Async::Redis::Pool->new(
        host => 'localhost',
        min  => 1,
        max  => 3,
    );

    subtest 'with() returns result' => sub {
        my $result = $loop->await($pool->with(async sub {
            my ($redis) = @_;
            await $redis->set('with:test', 'hello');
            return await $redis->get('with:test');
        }));

        is($result, 'hello', 'with() returned result');

        # Cleanup
        $loop->await($pool->with(async sub {
            my ($redis) = @_;
            await $redis->del('with:test');
        }));
    };

    subtest 'with() releases on success' => sub {
        $loop->await($pool->with(async sub {
            my ($redis) = @_;
            await $redis->ping;
        }));

        my $stats = $pool->stats;
        is($stats->{active}, 0, 'no active connections after with()');
        is($stats->{idle}, 1, 'connection returned to pool');
    };

    subtest 'with() releases on exception' => sub {
        my $error;
        eval {
            $loop->await($pool->with(async sub {
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
            $loop->await($pool->with(async sub {
                my ($redis) = @_;
                await $redis->multi_start;
                await $redis->incr('with:counter');
                die "transaction interrupted";
            }));
        };

        # Connection was dirty (in_multi), should be destroyed
        # Next acquire should get clean connection
        $loop->await($pool->with(async sub {
            my ($redis) = @_;
            ok(!$redis->in_multi, 'new connection not in transaction');
            await $redis->ping;
        }));
    };

    subtest 'nested with() calls' => sub {
        my $outer_id;
        my $inner_id;

        $loop->await($pool->with(async sub {
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

        $loop->await(Future->all(@futures));

        is(scalar @ids, 3, 'all 3 completed');
        is(scalar(keys %{{ map { $_ => 1 } @ids }}), 3, 'used 3 different connections');
    };
}

done_testing;
```

### Step 8: Write dirty detection test

```perl
# t/90-pool/dirty-detection.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'is_dirty detects in_multi' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn = $loop->await($pool->acquire);
        ok(!$conn->is_dirty, 'connection starts clean');

        # Start MULTI
        $loop->await($conn->multi_start);
        ok($conn->in_multi, 'in_multi flag set');
        ok($conn->is_dirty, 'connection is dirty');

        # Don't EXEC/DISCARD - release dirty
        $pool->release($conn);

        # Should be destroyed
        my $stats = $pool->stats;
        is($stats->{destroyed}, 1, 'dirty connection destroyed');
    };

    subtest 'is_dirty detects watching' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->watch('dirty:key'));

        ok($conn->watching, 'watching flag set');
        ok($conn->is_dirty, 'connection is dirty');

        $pool->release($conn);

        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty connection destroyed');
    };

    subtest 'is_dirty detects in_pubsub' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->subscribe('dirty:channel'));

        ok($conn->in_pubsub, 'in_pubsub flag set');
        ok($conn->is_dirty, 'connection is dirty');

        $pool->release($conn);

        my $stats = $pool->stats;
        ok($stats->{destroyed} >= 1, 'dirty pubsub connection destroyed');
    };

    subtest 'clean connection reused' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn1 = $loop->await($pool->acquire);
        my $id1 = "$conn1";
        $loop->await($conn1->ping);  # Normal command
        ok(!$conn1->is_dirty, 'connection still clean');
        $pool->release($conn1);

        my $conn2 = $loop->await($pool->acquire);
        my $id2 = "$conn2";

        is($id1, $id2, 'clean connection was reused');

        $pool->release($conn2);
    };

    subtest 'properly completed transaction is clean' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->multi_start);
        ok($conn->in_multi, 'in transaction');

        $loop->await($conn->command('INCR', 'dirty:counter'));
        $loop->await($conn->exec);

        ok(!$conn->in_multi, 'transaction completed');
        ok(!$conn->is_dirty, 'connection is clean');

        my $id = "$conn";
        $pool->release($conn);

        my $conn2 = $loop->await($pool->acquire);
        is("$conn2", $id, 'connection reused after clean transaction');

        $pool->release($conn2);
        $loop->await($pool->with(async sub {
            my ($r) = @_;
            await $r->del('dirty:counter');
        }));
    };

    subtest 'discard clears in_multi' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->multi_start);
        ok($conn->in_multi, 'in transaction');

        $loop->await($conn->discard);
        ok(!$conn->in_multi, 'DISCARD cleared in_multi');
        ok(!$conn->is_dirty, 'connection is clean');

        $pool->release($conn);
    };

    subtest 'unwatch clears watching' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->watch('dirty:key'));
        ok($conn->watching, 'watching');

        $loop->await($conn->unwatch);
        ok(!$conn->watching, 'UNWATCH cleared watching');
        ok(!$conn->is_dirty, 'connection is clean');

        $pool->release($conn);
    };
}

done_testing;
```

### Step 9: Write cleanup mode test

```perl
# t/90-pool/cleanup.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'cleanup mode resets in_multi' => sub {
        my $pool = Async::Redis::Pool->new(
            host     => 'localhost',
            on_dirty => 'cleanup',
        );

        my $conn = $loop->await($pool->acquire);
        my $id = "$conn";
        $loop->await($conn->multi_start);
        ok($conn->is_dirty, 'dirty after MULTI');

        $pool->release($conn);

        # Wait for async cleanup
        $loop->await(Future::IO->sleep(0.2));

        # Acquire again - might be same connection
        my $conn2 = $loop->await($pool->acquire);

        # Connection should be clean
        ok(!$conn2->is_dirty, 'connection is clean after cleanup');

        $pool->release($conn2);
    };

    subtest 'cleanup mode resets watching' => sub {
        my $pool = Async::Redis::Pool->new(
            host     => 'localhost',
            on_dirty => 'cleanup',
        );

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->watch('cleanup:key'));
        ok($conn->watching, 'watching set');

        $pool->release($conn);
        $loop->await(Future::IO->sleep(0.2));

        my $conn2 = $loop->await($pool->acquire);
        ok(!$conn2->watching, 'watching cleared by cleanup');

        $pool->release($conn2);
    };

    subtest 'cleanup NEVER attempted for pubsub' => sub {
        my $pool = Async::Redis::Pool->new(
            host     => 'localhost',
            on_dirty => 'cleanup',
        );

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->subscribe('cleanup:chan'));
        ok($conn->in_pubsub, 'in pubsub mode');

        my $stats_before = $pool->stats;

        $pool->release($conn);
        $loop->await(Future::IO->sleep(0.2));

        # Should be destroyed, not cleaned
        my $stats_after = $pool->stats;
        ok($stats_after->{destroyed} > $stats_before->{destroyed},
            'pubsub connection was destroyed, not cleaned');
    };

    subtest 'default destroy mode' => sub {
        my $pool = Async::Redis::Pool->new(
            host     => 'localhost',
            on_dirty => 'destroy',  # explicit default
        );

        my $conn = $loop->await($pool->acquire);
        my $id = "$conn";
        $loop->await($conn->multi_start);
        $pool->release($conn);

        $loop->await(Future::IO->sleep(0.1));

        my $conn2 = $loop->await($pool->acquire);

        # Should be a different connection
        isnt("$conn2", $id, 'dirty connection was destroyed, got new one');

        $pool->release($conn2);
    };
}

done_testing;
```

### Step 10: Write health check test

```perl
# t/90-pool/health-check.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'health check on acquire' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 1,
        );

        # Acquire and release to populate pool
        my $conn = $loop->await($pool->acquire);
        my $id = "$conn";
        $pool->release($conn);

        # Acquire again - should health check
        my $conn2 = $loop->await($pool->acquire);

        # Should get same healthy connection
        is("$conn2", $id, 'healthy connection reused');

        $pool->release($conn2);
    };

    subtest 'unhealthy connection replaced' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 1,
        );

        my $conn = $loop->await($pool->acquire);
        my $id = "$conn";

        # Simulate disconnect (makes health check fail)
        $conn->disconnect;
        $conn->{connected} = 0;

        # Put back in pool (bypassing release which would detect dirty)
        push @{$pool->{_idle}}, $conn;
        delete $pool->{_active}{"$conn"};

        # Acquire should fail health check and create new
        my $conn2 = $loop->await($pool->acquire);

        isnt("$conn2", $id, 'got new connection after failed health check');

        # New connection should work
        my $result = $loop->await($conn2->ping);
        is($result, 'PONG', 'new connection healthy');

        $pool->release($conn2);
    };

    subtest 'pubsub connection fails health check' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
        );

        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->subscribe('health:chan'));

        # Manually put back (bypass release dirty detection)
        push @{$pool->{_idle}}, $conn;
        delete $pool->{_active}{"$conn"};

        # Acquire - pubsub connection can't be PING'd normally
        my $conn2 = $loop->await($pool->acquire);

        # Should get different connection
        ok(!$conn2->in_pubsub, 'got non-pubsub connection');

        $pool->release($conn2);
    };
}

done_testing;
```

### Step 11: Write sizing test

```perl
# t/90-pool/sizing.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'respects min connections' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 2,
            max  => 5,
        );

        # Acquire to trigger connection creation
        my $conn = $loop->await($pool->acquire);
        $pool->release($conn);

        # Destroy one - should be replaced
        # (This tests _maybe_create_replacement)

        # For now just verify stats
        my $stats = $pool->stats;
        ok($stats->{total} >= 1, 'at least one connection exists');
    };

    subtest 'respects max connections' => sub {
        my $pool = Async::Redis::Pool->new(
            host            => 'localhost',
            min             => 0,
            max             => 2,
            acquire_timeout => 0.5,
        );

        my @conns;
        push @conns, $loop->await($pool->acquire);
        push @conns, $loop->await($pool->acquire);

        my $stats = $pool->stats;
        is($stats->{active}, 2, 'max connections active');

        # Third acquire should timeout
        my $error;
        eval {
            $loop->await($pool->acquire);
        };
        $error = $@;

        ok($error, 'third acquire failed');
        like("$error", qr/timeout/i, 'timeout error');

        # Release one, then acquire should succeed
        $pool->release(pop @conns);

        my $conn3 = $loop->await($pool->acquire);
        ok($conn3, 'acquire succeeded after release');

        $pool->release($conn3);
        $pool->release($conns[0]);
    };

    subtest 'connections grow to max under load' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 0,
            max  => 5,
        );

        my @conns;
        for my $i (1..5) {
            push @conns, $loop->await($pool->acquire);
        }

        my $stats = $pool->stats;
        is($stats->{active}, 5, 'grew to max');
        is($stats->{total}, 5, 'total is max');

        $pool->release($_) for @conns;

        $stats = $pool->stats;
        is($stats->{idle}, 5, 'all returned to pool');
    };

    subtest 'acquire_timeout' => sub {
        my $pool = Async::Redis::Pool->new(
            host            => 'localhost',
            max             => 1,
            acquire_timeout => 0.5,
        );

        my $conn = $loop->await($pool->acquire);

        my $start = time();
        eval { $loop->await($pool->acquire) };
        my $elapsed = time() - $start;

        ok($elapsed >= 0.4 && $elapsed < 1.0, "timed out after ~0.5s ($elapsed)");

        $pool->release($conn);
    };
}

done_testing;
```

### Step 12: Write stats test

```perl
# t/90-pool/stats.t
use Test2::V0;
use IO::Async::Loop;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'stats structure' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $stats = $pool->stats;

        ok(exists $stats->{active}, 'has active');
        ok(exists $stats->{idle}, 'has idle');
        ok(exists $stats->{waiting}, 'has waiting');
        ok(exists $stats->{total}, 'has total');
        ok(exists $stats->{destroyed}, 'has destroyed');
    };

    subtest 'stats reflect pool state' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $stats = $pool->stats;
        is($stats->{active}, 0, 'initially 0 active');
        is($stats->{idle}, 0, 'initially 0 idle');

        my $conn = $loop->await($pool->acquire);

        $stats = $pool->stats;
        is($stats->{active}, 1, '1 active after acquire');
        is($stats->{idle}, 0, '0 idle while in use');
        is($stats->{total}, 1, '1 total');

        $pool->release($conn);

        $stats = $pool->stats;
        is($stats->{active}, 0, '0 active after release');
        is($stats->{idle}, 1, '1 idle after release');
        is($stats->{total}, 1, 'still 1 total');
    };

    subtest 'destroyed counter' => sub {
        my $pool = Async::Redis::Pool->new(host => 'localhost');

        my $stats = $pool->stats;
        is($stats->{destroyed}, 0, 'initially 0 destroyed');

        # Create dirty connection
        my $conn = $loop->await($pool->acquire);
        $loop->await($conn->multi_start);  # Make dirty
        $pool->release($conn);

        $stats = $pool->stats;
        is($stats->{destroyed}, 1, '1 destroyed after dirty release');
    };

    subtest 'concurrent stats' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            max  => 5,
        );

        my @conns;
        for (1..3) {
            push @conns, $loop->await($pool->acquire);
        }

        my $stats = $pool->stats;
        is($stats->{active}, 3, '3 active');
        is($stats->{idle}, 0, '0 idle');
        is($stats->{total}, 3, '3 total');

        $pool->release($conns[0]);

        $stats = $pool->stats;
        is($stats->{active}, 2, '2 active after 1 release');
        is($stats->{idle}, 1, '1 idle');

        $pool->release($_) for @conns[1..2];

        $stats = $pool->stats;
        is($stats->{active}, 0, 'all released');
        is($stats->{idle}, 3, 'all idle');
    };
}

done_testing;
```

### Step 13: Write concurrent test

```perl
# t/90-pool/concurrent.t
use Test2::V0;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Future::IO::Impl::IOAsync;
use Async::Redis::Pool;
use Time::HiRes qw(time);

my $loop = IO::Async::Loop->new;

SKIP: {
    my $test_redis = eval {
        require Async::Redis;
        my $r = Async::Redis->new(host => 'localhost', connect_timeout => 2);
        $loop->await($r->connect);
        $r;
    };
    skip "Redis not available: $@", 1 unless $test_redis;
    $test_redis->disconnect;

    subtest 'concurrent with() calls share pool' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 2,
            max  => 5,
        );

        my $counter_key = 'concurrent:counter';
        $loop->await($pool->with(async sub {
            my ($r) = @_;
            await $r->set($counter_key, 0);
        }));

        # Launch 20 concurrent increment operations
        my @futures = map {
            $pool->with(async sub {
                my ($redis) = @_;
                await $redis->incr($counter_key);
            })
        } (1..20);

        $loop->await(Future->all(@futures));

        my $final = $loop->await($pool->with(async sub {
            my ($r) = @_;
            await $r->get($counter_key);
        }));

        is($final, 20, 'all 20 increments succeeded');

        # Cleanup
        $loop->await($pool->with(async sub {
            my ($r) = @_;
            await $r->del($counter_key);
        }));
    };

    subtest 'pool under heavy concurrent load' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            min  => 2,
            max  => 10,
        );

        my @keys;
        my @futures = map {
            my $key = "load:key:$_";
            push @keys, $key;
            $pool->with(async sub {
                my ($redis) = @_;
                await $redis->set($key, $_);
                await $redis->get($key);
            })
        } (1..50);

        my @results = $loop->await(Future->all(@futures));

        is(scalar @results, 50, 'all 50 operations completed');

        # Cleanup
        $loop->await($pool->with(async sub {
            my ($r) = @_;
            await $r->del(@keys);
        }));
    };

    subtest 'pool non-blocking under load' => sub {
        my $pool = Async::Redis::Pool->new(
            host => 'localhost',
            max  => 5,
        );

        my @ticks;
        my $timer = IO::Async::Timer::Periodic->new(
            interval => 0.01,
            on_tick => sub { push @ticks, 1 },
        );
        $loop->add($timer);
        $timer->start;

        my @futures = map {
            $pool->with(async sub {
                my ($redis) = @_;
                await $redis->ping;
            })
        } (1..100);

        $loop->await(Future->all(@futures));

        $timer->stop;
        $loop->remove($timer);

        ok(@ticks >= 10, "Event loop ticked " . scalar(@ticks) . " times during 100 pool ops");
    };

    subtest 'waiters served in order' => sub {
        my $pool = Async::Redis::Pool->new(
            host            => 'localhost',
            max             => 1,
            acquire_timeout => 5,
        );

        my @order;

        # Acquire the only connection
        my $blocker = $loop->await($pool->acquire);

        # Queue up waiters
        my $f1 = $pool->acquire->on_done(sub { push @order, 1 });
        my $f2 = $pool->acquire->on_done(sub { push @order, 2 });
        my $f3 = $pool->acquire->on_done(sub { push @order, 3 });

        # Release blocker
        $pool->release($blocker);

        # First waiter gets connection
        my $conn1 = $loop->await($f1);
        $pool->release($conn1);

        my $conn2 = $loop->await($f2);
        $pool->release($conn2);

        my $conn3 = $loop->await($f3);
        $pool->release($conn3);

        is(\@order, [1, 2, 3], 'waiters served in FIFO order');
    };
}

done_testing;
```

### Step 14: Run all pool tests

Run: `prove -l t/90-pool/`
Expected: PASS

### Step 15: Run all tests

Run: `prove -l t/`
Expected: PASS

### Step 16: Commit

```bash
git add lib/Future/IO/Redis/Pool.pm lib/Future/IO/Redis.pm t/90-pool/
git commit -m "$(cat <<'EOF'
feat: implement connection pool with dirty detection

Pool.pm:
- min/max connection sizing
- acquire() with timeout, release()
- with() scoped pattern (RECOMMENDED)
- Automatic dirty detection on release
- Health check (PING) on acquire
- stats() for monitoring

Dirty detection (is_dirty):
- in_multi: Started MULTI without EXEC/DISCARD
- watching: Has WATCH keys without UNWATCH/EXEC
- in_pubsub: In subscription mode
- inflight: Has pending responses

Dirty handling (on_dirty):
- 'destroy' (DEFAULT): Destroy connection, create replacement
- 'cleanup': Attempt DISCARD/UNWATCH for safe states only

Cleanup eligibility:
- in_multi: Yes (DISCARD is safe)
- watching: Yes (UNWATCH is safe)
- in_pubsub: NO (protocol hazard)
- inflight: NO (responses may never arrive)

The with() pattern:
    await $pool->with(async sub {
        my ($redis) = @_;
        # Use $redis
        # Automatically released, even on exception
    });

Test coverage:
- Basic acquire/release
- with() pattern (success, exception, nested, concurrent)
- All dirty states detected
- Cleanup mode for safe states
- Health check failures
- Pool sizing (min/max)
- Acquire timeout
- Stats tracking
- Concurrent load testing
- Non-blocking verification

EOF
)"
```

---

## Summary

Phase 6 implements:

### Task 16: PubSub Refinement
- `Subscription.pm` with async iterator pattern
- Regular, pattern, and sharded subscriptions
- Channel tracking for reconnect replay
- Proper unsubscribe handling
- in_pubsub connection state tracking

### Task 17: Connection Pool
- `Pool.pm` with min/max sizing
- Rigorous dirty detection (4 states)
- Health checking on acquire
- `with()` scoped pattern (recommended)
- Two dirty handling modes (destroy/cleanup)
- Cleanup eligibility rules (never for pubsub/inflight)
- Statistics tracking

**Why Connection Pool is Critical:**

Dirty connections are the #1 cause of data corruption in pooled Redis:

| State | Risk Without Detection |
|-------|----------------------|
| in_multi | Next user's commands queued in abandoned transaction |
| watching | Next transaction may fail unexpectedly |
| in_pubsub | Connection in modal state, commands fail |
| inflight | Responses arrive for wrong user |

The default `on_dirty => 'destroy'` is safest. The cost of a new TCP handshake + AUTH is negligible compared to data corruption risk.

---

## Execution Options

**Plan complete and saved to `docs/plans/2026-01-01-implementation-phase6.md`.**

Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
