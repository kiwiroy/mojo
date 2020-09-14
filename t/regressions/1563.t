#!/usr/bin/env perl

use Mojolicious::Lite -signatures;
use Test::Mojo;
use Test::More;
use Mojo::IOLoop;

my ($server_close, $client_close) = (0, 0);

# Listen on port 3000
Mojo::IOLoop->server({port => 3000} => sub ($loop, $stream, $id) {
  $stream->on(read => sub ($stream, $bytes) {
    # Write response
    $stream->write('HTTP/1.1 200 OK');
  });
  $stream->on(close => sub { $server_close++; });
});

# Connect to port 3000
my $id = Mojo::IOLoop->client({port => 3000} => sub ($loop, $err, $stream) {
  # Write request
  $stream->write("GET / HTTP/1.1\x0d\x0a\x0d\x0a");
  $stream->on(close => sub { $client_close++ });
});

# Add a timer
Mojo::IOLoop->timer(1 => sub ($loop) {
  local $$ = -99;
  $loop->reset;
  $loop->remove($id)
});

# Start event loop if necessary
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

is $client_close, 0, 'correct';
is $server_close, 0, 'correct';

done_testing;
