package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use IO::Async::Function;
use EvalServer::Config;

use Data::Dumper;

use Moo;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});

sub init {
  my ($self) = @_;

  my $func = IO::Async::Function->new(
    max_workers => config('evalserver')->{max_workers},
    max_worker_calls => config('evalserver')->{max_evals_per_worker} // 0,
    idle_timeout => config('evalserver')->{worker_idle_timeout},
    code => sub {
      my ($evaldata) = @_; 

  });
}

sub run {
  my ($self) = @_;

  print Dumper(config()->language());
}

1;
