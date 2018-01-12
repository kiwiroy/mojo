use Mojo::Base -strict;
use Test::More;

package ArrayBased;

use Mojo::Base -base;

sub new { bless [], shift; }

__PACKAGE__->io_attr('test' => sub { "boo"; });

__PACKAGE__->io_attr('foo');

__PACKAGE__->io_attr('bar' => 1);

package main;

my $t = ArrayBased->new();

isa_ok $t, 'ArrayBased';
is $t->test, 'boo', 'scary';
$t->test("something");
is $t->test, 'something', 'happy';
is $t->foo, undef, 'undef';
is $t->foo('this'), $t, 'chain';

done_testing();
