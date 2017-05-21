package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use IO::Async::Function;
use EvalServer::Config;
use EvalServer::Sandbox;

use Data::Dumper;
use POSIX qw/_exit/;

use Moo;
use IPC::Run qw/harness/;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});
has _inited => (is => 'rw', default => 0);

my $es_config = config->evalserver;

sub init {
  my ($self) = @_;
  return if $self->_inited();

  $self->loop->add($worker_func);

  $self->_inited(1);
}

sub run {
  my ($self) = @_;

  #print Dumper(config);
  $self->init();
  #$self->loop->run();

  my $evalobj = {
    files => {
      __code => "print 1"
    },
    lang => "perl"
  };

  my @res = eval {$worker_func->call(args => [$evalobj])->get()};

  print Dumper({r=>\@res, e=>$@});
}

sub worker {
  my ($evalobj) = @_;

  my %files = %{$evalobj->{files}};

  # TODO these must both disappear
  die "Multi-file not supported" if (keys %files != 1);
  die "There must be __code" if (!$files{__code});

  my $code = $files{__code};
  my $lang = $evalobj->{lang};

  # TODO this could be done via IO::Async somehow now without IPC::Run I think.  But it'll take an IO::Async something that supports the namespace stuff
  my $in = '';
  my $out = '';
  my $origpid = $$;
  my $h = harness sub {$|++; EvalServer::Sandbox::run_eval($lang, $code, \%files); _exit(0);}, '<', \$in, '>&', \$out;
  my ($start_time, $end_time);
  eval {
    $h->start();
    $start_time = time();
    while($h->pumpable()) {
      $h->pump_nb();

      sleep(0.1); # yield some time
      die "Timeout" if (time() - $start_time) > $es_config->timeout();
    }
  };
  $end_time = time();
  my $err = $@;
  $h->kill_kill; # shouldn't be necessary but it's safe
  eval {$h->finish();} if $err;

  _exit(0) if ($origpid != $$); # WHY IS THIS HAPPENING?

  print STDERR Dumper({out => $out, pid => $$, opid => $origpid});

  return "$out";  
}

1;
