use strict;
use warnings;
BEGIN {
    # looks like more chance to get this error with non-blocking resolving disabled
    $ENV{MOJO_NO_NNR} = 1;
}
use Mojo::UserAgent;

for (1..30) {
    get_next();
}

sub get_next {
    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(10);
    $ua->request_timeout(10);
    $ua->get('http://oleghere.xyz/', sub {
        undef $ua;
        get_next();
    });
}

Mojo::IOLoop->start();
