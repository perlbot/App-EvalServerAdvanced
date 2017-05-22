package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use IO::Async::Function;
use EvalServer::Config;
use EvalServer::Sandbox;
use EvalServer::JobManager;

use Data::Dumper;
use POSIX qw/_exit/;

use Moo;
use IPC::Run qw/harness/;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});
has _inited => (is => 'rw', default => 0);
has jobman => (is => 'ro', default => sub {EvalServer::JobManager->new(loop => $_[0]->loop)});

sub init {
  my ($self) = @_;
  return if $self->_inited();

  $self->_inited(1);
}

sub run {
  my ($self) = @_;

  #print Dumper(config);
  $self->init();
  #$self->loop->run();

  my $evalobj = {
    files => {
      __code => 'my $t = rand()*15; print $t; sleep $t'
    },
    language => "perl",
    priority => "realtime"
  };

  my @futures = map {$self->jobman->add_job({%$evalobj})} 0..3;

  $|++;

  for my $f (@futures) {
    my @res = eval{$f->get()};
    print Dumper({pid => $$, r=>\@res, e=>$@});
  }
}

1;