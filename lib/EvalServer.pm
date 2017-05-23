package EvalServer;

use strict;
use EvalServer::Sandbox;
use IO::Async::Loop;
use IO::Async::Function;
use EvalServer::Config;
use EvalServer::Sandbox;
use EvalServer::JobManager;
use Function::Parameters;
use EvalServer::Protocol;

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
  my $es_self = $self;

  my $listener = $self->loop->listen(
    service => config->evalserver->port,
    host => config->evalserver->host,
    socktype => 'stream',
    on_stream => fun ($stream) {
      $stream->configure(
        on_read => method ($buffref, $eof) {
          my ($res, $message, $newbuf) = eval{decode_message($$buffref)};

          # We had an error when decoding the incoming packets, tell them and close the connection.
          if ($@) {
            my $message = encode_message(warning => {message => $@});
            $stream->write($message);
            $stream->close_when_empty();
          }

          if ($res) {
            #$stream->write("Got message of type: ".ref($message)."\n");
            $$buffref = $newbuf;

            if ($message->isa("EvalServer::Protocol::Eval")) {
              my $sequence = $message->sequence;

              my $prio = ($message->prio->has_pr_deadline ? "deadline" :
                         ($message->prio->has_pr_batch    ? "batch" : "realtime"));

              my $evalobj = {
                files => {map {
                      ($_->filename => $_->contents)
                  } $message->{files}->@*},
                priority => $prio,
                language => $message->language,
              };

              if ($prio eq 'deadline') {
                $evalobj->{priority_deadline} = $message->prio->pr_deadline->milliseconds;  
              };

              my $future = $es_self->jobman->add_job($evalobj);
              
              $future->on_ready(fun ($future) {
                my $output = $future->get();
                my $response = encode_message(response => {sequence => $sequence, contents => $output});
                $stream->write($response);
              });

            } else {
              my $response = encode_message(warning => {message => "Got unhandled packet type, ". ref($message)});
              $stream->write($response);
            }
          }

          return 0;
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
  $self->init();
  $self->loop->run();

  return;
}

1;