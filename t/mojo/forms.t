use Mojo::Base -strict;

BEGIN {
  $ENV{MOJO_NO_NNR}  = $ENV{MOJO_NO_SOCKS} = $ENV{MOJO_NO_TLS} = 1;
  $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll';
}

use Test::More;
use Mojo::IOLoop;
use Mojo::Message::Request;
use Mojo::UserAgent;
use Mojolicious::Lite;
use Mojo::DOM::HTML qw{awaken_form};
use Mojo::Util qw{dumper};
# Silence
app->log->level('debug')->unsubscribe('message');

get '/' => sub {
  my $c = shift;
  $c->render(template => 'index');
};

get '/foo' => sub {
  my $c = shift;
  $c->render(template => 'thanks');
};

my $ua = Mojo::UserAgent->new;
my $tx = $ua->get('/');
my $form = $tx->res->dom->at('form');
$form->val($tx->req->url);
$tx = $ua->build_tx(awaken_form $form);
diag $tx->req->url;
$ua->start($tx);
diag explain $tx->res->body;


$tx = $ua->build_tx(awaken_form $form, $tx->req->url, {a => 'z'});
$ua->start($tx);
diag explain $tx->res->body;

$ua->get_p('/')->then(sub {
  my $tx     = shift;
  my $submit = $ua->build_tx(awaken_form $tx->res->dom->at('form'), $tx->req->url, {a => 'x'});
  my $url    = $submit->req->url;
  $submit->req->url($url->to_abs($tx->req->url)) unless $url->is_abs;
  diag $submit->req->url;
  return $ua->start_p($submit);
})->then(sub {
  my $tx = shift;
  diag explain $tx->res->body;
})->catch(sub {
  my $err = shift;
  warn "Connection error: $err";
})->wait;

ok 1;

done_testing;

__DATA__
@@ index.html.ep
% layout 'default';
% title 'Welcome';
<h1>Welcome to the Mojolicious real-time web framework!</h1>
<div>
  <form action="/foo">
    <p>Test</p>
    <input type="text" name="a" value="A" />
    <input type="checkbox" name="q">
    <input type="checkbox" checked name="b" value="B">
    <input type="radio" name="r">
    <input type="radio" checked name="c" value="C">
    <input name="s">
    <input type="checkbox" name="t" value="">
    <input type=text name="u">
    <select multiple name="f">
      <option value="F">G</option>
      <optgroup>
        <option>H</option>
        <option selected>I</option>
        <option selected disabled>V</option>
      </optgroup>
      <option value="J" selected>K</option>
      <optgroup disabled>
        <option selected>I2</option>
      </optgroup>
    </select>
    <select name="n"><option>N</option></select>
    <select multiple name="q"><option>Q</option></select>
    <select name="y" disabled>
      <option selected>Y</option>
    </select>
    <select name="d">
      <option selected>R</option>
      <option selected>D</option>
    </select>
    <textarea name="m">M</textarea>
    <button name="o" value="O">No!</button>
    <input type="submit" name="p" value="P" />
  </form>
</div>
@@ thanks.html.ep
% for my $name(sort keys %{$c->req->query_params->to_hash}) {
<%= $name; %> = <%= $c->req->params->param($name); %>
% }
  
@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body><%= content %></body>
</html>
