package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use IO::Async::Function;
use EvalServer::Config;
use EvalServer::Sandbox;
use EvalServer::JobManager;
use Function::Parameters;

use Data::Dumper;
use POSIX qw/_exit/;

use Moo;
use IPC::Run qw/harness/;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});
has _inited => (is => 'rw', default => 0);
has jobman => (is => 'ro', default => sub {EvalServer::JobManager->new(loop => $_[0]->loop)});
has listener => (is => 'rw');

method init {
  return if $self->_inited();

  my $listener = $self->loop->listen(
    service => config->evalserver->port,
    host => config->evalserver->host,
    socktype => 'stream',
    on_stream => fun ($stream) {
      $stream->configure(
        on_read => method ($buffref, $eof) {
          $self->write($$buffref);
          $$buffref = '';
          0
        }
      );

      $self->loop->add($stream);
    },

    on_resolve_error => sub {die "Cannot resolve - $_[1]\n"},
    on_listen_error => sub {die "Cannot listen - $_[1]\n"},

    on_listen => method {
        warn "listening on: " . $self->sockhost . ':' . $self->sockport . "\n";
    },
  );

  $self->_inited(1);
}

method run {
  #print Dumper(config);
  $self->init();
  $self->loop->run();

  return;

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