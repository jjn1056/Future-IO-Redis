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
