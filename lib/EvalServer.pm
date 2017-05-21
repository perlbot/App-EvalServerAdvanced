package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use IO::Async::Function;
use EvalServer::Config;
use EvalServer::Sandbox;

use Data::Dumper;

use Moo;
use IPC::Run qw/harness/;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});
has _inited => (is => 'rw', default => 0);

my $es_config = config('evalserver');

my $worker_func = IO::Async::Function->new(
    max_workers => $es_config->max_workers // 5,
    min_workers => $es_config->min_workers // 0,
    max_worker_calls => $es_config->max_evals_per_worker // 0,
    idle_timeout => $es_config->worker_idle_timeout // 30,
    code => \&worker);

sub init {
  my ($self) = @_;
  return if $self->_inited();

  $self->loop->add($worker_func);

  $self->_inited(1);
}

sub run {
  my ($self) = @_;

  print Dumper(config);
  #$self->init();
  #$self->loop->run();
}

sub worker {
  my ($evalobj) = @_;

  my %files = %{$evalobj->{files}};

  # TODO these must both disappear
  die "Multi-file not supported" if (keys %files != 1);
  die "There must be __code" if (!$files{__code});

  my $code = $files{__code};
  my $lang = $evalobj->{lang};

  # TODO this is a weird inversion of things since run_eval can't return a real value due to namespacing
  my $in = '';
  my $out = '';
  my $h = harness sub {EvalServer::Sandbox::run_eval($lang, $code, \%files)}, '<', \$in, '>&', \$out;
  my ($start_time, $end_time);
  eval {
    $h->start();
    $start_time = time();
    while($h->pumpable()) {
      $h->pump_nb();

      sleep(0.1); # yield some time
      die "Timeout" if time() - $start_time > $es_config->timeout();
    }
  };
  $end_time = time();
  my $err = $@;
  $h->kill_kill; # shouldn't be necessary but it's safe
  eval {$h->finish();} if $err;

  return $out;  
}

1;
