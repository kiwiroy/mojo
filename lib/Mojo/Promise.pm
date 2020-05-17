package Mojo::Promise;
use Mojo::Base -base;

use Carp qw(carp);
use Mojo::IOLoop;
use Mojo::Util qw(deprecated);
use Scalar::Util qw(blessed);

has ioloop => sub { Mojo::IOLoop->singleton }, weak => 1;

sub AWAIT_CLONE { _await('clone', @_) }

sub AWAIT_DONE { shift->resolve(@_) }
sub AWAIT_FAIL { shift->reject(@_) }

sub AWAIT_GET {
  my $self    = shift;
  my @results = @{$self->{result} // []};
  die $results[0] unless $self->{status} eq 'resolve';
  return wantarray ? @results : $results[0];
}

sub AWAIT_IS_CANCELLED {undef}

sub AWAIT_IS_READY {
  my $self = shift;
  $self->{handled} = 1;
  return !!$self->{result} && !@{$self->{resolve}} && !@{$self->{reject}};
}

sub AWAIT_NEW_DONE { _await('resolve', @_) }
sub AWAIT_NEW_FAIL { _await('reject',  @_) }

sub AWAIT_ON_CANCEL { }

sub AWAIT_ON_READY {
  shift->_finally(0, @_)->catch(sub { });
}

sub DESTROY {
  my $self = shift;
  return if $self->{handled} || ($self->{status} // '') ne 'reject';
  carp "Unhandled rejected promise: @{$self->{result}}" if $self->{result};
}

sub all         { _all(2, @_) }
sub all_settled { _all(0, @_) }
sub any         { _all(3, @_) }

sub catch { shift->then(undef, shift) }

sub clone { $_[0]->new->ioloop($_[0]->ioloop) }

sub finally { shift->_finally(1, @_) }

sub new {
  my $self = shift->SUPER::new;
  shift->(sub { $self->resolve(@_) }, sub { $self->reject(@_) }) if @_;
  return $self;
}

sub race { _all(1, @_) }

sub reject  { shift->_settle('reject',  @_) }
sub resolve { shift->_settle('resolve', @_) }

sub then {
  my ($self, $resolve, $reject) = @_;

  my $new = $self->clone;
  $self->{handled} = 1;
  push @{$self->{resolve}}, sub { _then_cb($new, $resolve, 'resolve', @_) };
  push @{$self->{reject}},  sub { _then_cb($new, $reject,  'reject',  @_) };

  $self->_defer if $self->{result};

  return $new;
}

sub timer   { shift->_timer('resolve', @_) }
sub timeout { shift->_timer('reject',  @_) }

sub wait {
  my $self = shift;
  return if (my $loop = $self->ioloop)->is_running;
  my $done;
  $self->_finally(0, sub { $done++; $loop->stop })->catch(sub { });
  $loop->start until $done;
}

sub _all {
  my ($type, $class, @promises) = @_;

  my $all       = $promises[0]->clone;
  my $results   = [];
  my $remaining = scalar @promises;
  for my $i (0 .. $#promises) {

    # "race"
    if ($type == 1) {
      $promises[$i]
        ->then(sub { $all->resolve(@_); () }, sub { $all->reject(@_); () });
    }

    # "all"
    elsif ($type == 2) {
      $promises[$i]->then(
        sub {
          $results->[$i] = [@_];
          $all->resolve(@$results) if --$remaining <= 0;
          return ();
        },
        sub { $all->reject(@_); () }
      );
    }

    # "any"
    elsif ($type == 3) {
      $promises[$i]->then(
        sub { $all->resolve(@_); () },
        sub {
          $results->[$i] = [@_];
          $all->reject(@$results) if --$remaining <= 0;
          return ();
        }
      );
    }

    # "all_settled"
    else {
      $promises[$i]->then(
        sub {
          $results->[$i] = {status => 'fulfilled', value => [@_]};
          $all->resolve(@$results) if --$remaining <= 0;
          return ();
        },
        sub {
          $results->[$i] = {status => 'rejected', reason => [@_]};
          $all->resolve(@$results) if --$remaining <= 0;
          return ();
        }
      );
    }
  }

  return $all;
}

sub _await {
  my ($method, $class) = (shift, shift);
  my $promise = $class->$method(@_);
  $promise->{cycle} = $promise;
  return $promise;
}

sub _defer {
  my $self = shift;

  return unless my $result = $self->{result};
  my $cbs = $self->{status} eq 'resolve' ? $self->{resolve} : $self->{reject};
  @{$self}{qw(cycle resolve reject)} = (undef, [], []);

  $self->ioloop->next_tick(sub { $_->(@$result) for @$cbs });
}

sub _finally {
  my ($self, $handled, $finally) = @_;

  my $new = $self->clone;
  $self->{handled} = 1 if $handled;
  push @{$self->{resolve}}, sub { _finally_cb($new, $finally, 'resolve', @_) };
  push @{$self->{reject}},  sub { _finally_cb($new, $finally, 'reject',  @_) };

  $self->_defer if $self->{result};

  return $new;
}

sub _finally_cb {
  my ($new, $finally, $method, @result) = @_;
  return $new->reject($@) unless eval { $finally->(); 1 };
  return $new->$method(@result);
}

sub _settle {
  my ($self, $status, @result) = @_;

  my $thenable = blessed $result[0] && $result[0]->can('then');
  unless (ref $self) {
    return $result[0]
      if $status eq 'resolve' && $thenable && $result[0]->isa('Mojo::Promise');
    $self = $self->new;
  }

  if ($thenable) {
    $result[0]
      ->then(sub { $self->resolve(@_); () }, sub { $self->reject(@_); () });
  }

  elsif (!$self->{result}) {
    @{$self}{qw(result status)} = (\@result, $status);
    $self->_defer;
  }

  return $self;
}

sub _then_cb {
  my ($new, $cb, $method, @result) = @_;

  return $new->$method(@result) unless defined $cb;

  my @res;
  return $new->reject($@) unless eval { @res = $cb->(@result); 1 };
  return $new->resolve(@res);
}

sub _timer {
  my ($self, $method, $after, @result) = @_;
  $self = $self->new unless ref $self;
  $result[0] = 'Promise timeout' if $method eq 'reject' && !@result;
  $self->ioloop->timer($after => sub { $self->$method(@result) });
  return $self;
}

1;

=encoding utf8

=head1 NAME

Mojo::Promise - Promises/A+

=head1 SYNOPSIS

  use Mojo::Promise;
  use Mojo::UserAgent;

  # Wrap continuation-passing style APIs with promises
  my $ua = Mojo::UserAgent->new;
  sub get_p {
    my $promise = Mojo::Promise->new;
    $ua->get(@_ => sub {
      my ($ua, $tx) = @_;
      my $err = $tx->error;
      if   (!$err || $err->{code}) { $promise->resolve($tx) }
      else                         { $promise->reject($err->{message}) }
    });
    return $promise;
  }

  # Perform non-blocking operations sequentially
  get_p('https://mojolicious.org')->then(sub {
    my $mojo = shift;
    say $mojo->res->code;
    return get('https://metacpan.org');
  })->then(sub {
    my $cpan = shift;
    say $cpan->res->code;
  })->catch(sub {
    my $err = shift;
    warn "Something went wrong: $err";
  })->wait;

  # Synchronize non-blocking operations (all)
  my $mojo = get_p('https://mojolicious.org');
  my $cpan = get_p('https://metacpan.org');
  Mojo::Promise->all($mojo, $cpan)->then(sub {
    my ($mojo, $cpan) = @_;
    say $mojo->[0]->res->code;
    say $cpan->[0]->res->code;
  })->catch(sub {
    my $err = shift;
    warn "Something went wrong: $err";
  })->wait;

  # Synchronize non-blocking operations (race)
  my $mojo = get_p('https://mojolicious.org');
  my $cpan = get_p('https://metacpan.org');
  Mojo::Promise->race($mojo, $cpan)->then(sub {
    my $tx = shift;
    say $tx->req->url, ' won!';
  })->catch(sub {
    my $err = shift;
    warn "Something went wrong: $err";
  })->wait;

=head1 DESCRIPTION

L<Mojo::Promise> is a Perl-ish implementation of
L<Promises/A+|https://promisesaplus.com> and a superset of
L<ES6 Promises|https://duckduckgo.com/?q=\mdn%20Promise>.

=head1 STATES

A promise is an object representing the eventual completion or failure of a
non-blocking operation. It allows non-blocking functions to return values, like
blocking functions. But instead of immediately returning the final value, the
non-blocking function returns a promise to supply the value at some point in the
future.

A promise can be in one of three states:

=over 2

=item pending

Initial state, neither fulfilled nor rejected.

=item fulfilled

Meaning that the operation completed successfully.

=item rejected

Meaning that the operation failed.

=back

A pending promise can either be fulfilled with a value or rejected with a
reason. When either happens, the associated handlers queued up by a promise's
L</"then"> method are called.

=head1 ATTRIBUTES

L<Mojo::Promise> implements the following attributes.

=head2 ioloop

  my $loop = $promise->ioloop;
  $promise = $promise->ioloop(Mojo::IOLoop->new);

Event loop object to control, defaults to the global L<Mojo::IOLoop> singleton.
Note that this attribute is weakened.

=head1 METHODS

L<Mojo::Promise> inherits all methods from L<Mojo::Base> and implements
the following new ones.

=head2 all

  my $new = Mojo::Promise->all(@promises);

Returns a new L<Mojo::Promise> object that either fulfills when all of the
passed L<Mojo::Promise> objects have fulfilled or rejects as soon as one of them
rejects. If the returned promise fulfills, it is fulfilled with the values from
the fulfilled promises in the same order as the passed promises.

=head2 all_settled

  my $new = Mojo::Promise->all_settled(@promises);

Returns a new L<Mojo::Promise> object that fulfills when all of the passed
L<Mojo::Promise> objects have fulfilled or rejected, with hash references that
describe the outcome of each promise.

=head2 any

  my $new = Mojo::Promise->any(@promises);

Returns a new L<Mojo::Promise> object that fulfills as soon as one of
the passed L<Mojo::Promise> objects fulfills, with the value from that promise.
If no promises fulfill, it is rejected with the reasons from the rejected
promises in the same order as the passed promises. Note that this method is
B<EXPERIMENTAL> and might change without warning!

=head2 catch

  my $new = $promise->catch(sub {...});

Appends a rejection handler callback to the promise, and returns a new
L<Mojo::Promise> object resolving to the return value of the callback if it is
called, or to its original fulfillment value if the promise is instead
fulfilled.

  # Longer version
  my $new = $promise->then(undef, sub {...});

  # Pass along the rejection reason
  $promise->catch(sub {
    my @reason = @_;
    warn "Something went wrong: $reason[0]";
    return @reason;
  });

  # Change the rejection reason
  $promise->catch(sub {
    my @reason = @_;
    return "This is bad: $reason[0]";
  });

=head2 clone

  my $new = $promise->clone;

Return a new L<Mojo::Promise> object cloned from this promise that is still
pending.

=head2 finally

  my $new = $promise->finally(sub {...});

Appends a fulfillment and rejection handler to the promise, and returns a new
L<Mojo::Promise> object resolving to the original fulfillment value or rejection
reason.

  # Do something on fulfillment and rejection
  $promise->finally(sub {
    say "We are done!";
  });

=head2 new

  my $promise = Mojo::Promise->new;
  my $promise = Mojo::Promise->new(sub {...});

Construct a new L<Mojo::Promise> object.

  # Wrap a continuation-passing style API
  my $promise = Mojo::Promise->new(sub {
    my ($resolve, $reject) = @_;
    Mojo::IOLoop->timer(5 => sub {
      if (int rand 2) { $resolve->('Lucky!') }
      else            { $reject->('Unlucky!') }
    });
  });

=head2 race

  my $new = Mojo::Promise->race(@promises);

Returns a new L<Mojo::Promise> object that fulfills or rejects as soon as one of
the passed L<Mojo::Promise> objects fulfills or rejects, with the value or
reason from that promise.

=head2 reject

  my $new  = Mojo::Promise->reject(@reason);
  $promise = $promise->reject(@reason);

Build rejected L<Mojo::Promise> object or reject the promise with one or more
rejection reasons.

  # Longer version
  my $promise = Mojo::Promise->new->reject(@reason);

=head2 resolve

  my $new  = Mojo::Promise->resolve(@value);
  $promise = $promise->resolve(@value);

Build resolved L<Mojo::Promise> object or resolve the promise with one or more
fulfillment values.

  # Longer version
  my $promise = Mojo::Promise->new->resolve(@value);

=head2 then

  my $new = $promise->then(sub {...});
  my $new = $promise->then(sub {...}, sub {...});
  my $new = $promise->then(undef, sub {...});

Appends fulfillment and rejection handlers to the promise, and returns a new
L<Mojo::Promise> object resolving to the return value of the called handler.

  # Pass along the fulfillment value or rejection reason
  $promise->then(
    sub {
      my @value = @_;
      say "The result is $value[0]";
      return @value;
    },
    sub {
      my @reason = @_;
      warn "Something went wrong: $reason[0]";
      return @reason;
    }
  );

  # Change the fulfillment value or rejection reason
  $promise->then(
    sub {
      my @value = @_;
      return "This is good: $value[0]";
    },
    sub {
      my @reason = @_;
      return "This is bad: $reason[0]";
    }
  );

=head2 timer

  my $new  = Mojo::Promise->timer(5 => 'Success!');
  $promise = $promise->timer(5 => 'Success!');
  $promise = $promise->timer(5);

Create a new L<Mojo::Promise> object with a timer or attach a timer to an
existing promise. The promise will be resolved after the given amount of time in
seconds with or without a value. Note that this method is B<EXPERIMENTAL> and
might change without warning!

=head2 timeout

  my $new  = Mojo::Promise->timeout(5 => 'Timeout!');
  $promise = $promise->timeout(5 => 'Timeout!');
  $promise = $promise->timeout(5);

Create a new L<Mojo::Promise> object with a timeout or attach a timeout to an
existing promise. The promise will be rejected after the given amount of time in
seconds with a reason, which defaults to C<Promise timeout>. Note that this
method is B<EXPERIMENTAL> and might change without warning!

=head2 wait

  $promise->wait;

Start L</"ioloop"> and stop it again once the promise has been fulfilled or
rejected, does nothing when L</"ioloop"> is already running.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
