package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use EvalServer::Config;

use Data::Dumper;

use Moo;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});

sub run {
  my ($self) = @_;

  print Dumper(EvalServer::Config::config());
}

1;
