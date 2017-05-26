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
use EvalServer::Log;

use Data::Dumper;
use POSIX qw/_exit/;

use Moo;
use IPC::Run qw/harness/;

has loop => (is => 'ro', lazy => 1, default => sub {IO::Async::Loop->new()});
has _inited => (is => 'rw', default => 0);
has jobman => (is => 'ro', default => sub {EvalServer::JobManager->new(loop => $_[0]->loop)});
has listener => (is => 'rw');

has session_counter => (is => 'rw', default => 0);
has sessions => (is => 'ro', default => sub {+{}});

method new_session_id() {
  my $c = $self->session_counter + 1;
  $self->session_counter($c);

  return $c;
}

method init {
  return if $self->_inited();
  my $es_self = $self;

  my $listener = $self->loop->listen(
    service => config->evalserver->port,
    host => config->evalserver->host,
    socktype => 'stream',
    on_stream => fun ($stream) {
      my $session_id = $self->new_session_id;
      $self->sessions->{$session_id} = {}; # init the session

      my $close_session = sub {
        debug "Closing session $session_id! ";
        for my $sequence (keys $self->sessions->{$session_id}{jobs}->%*) {
          my $job = $self->sessions->{$session_id}{jobs}{$sequence};
          
          $job->{future}->fail("Session ended") unless $job->{future}->is_ready;
          $job->{canceled} = 1; # Mark them as canceled
        }

        delete $self->sessions->{$session_id}; # delete the session references
      };

      $stream->configure(
        on_read_eof => sub {debug "read_eof"; $close_session->()},
        on_write_eof => sub {debug "write_eof"; $close_session->()},

        on_read => method ($buffref, $eof) {
          my ($res, $message, $newbuf) = eval{decode_message($$buffref)};
          debug sprintf("packet decode %d %d %d: %d", $res, length($message//''), length($newbuf//''), $eof);

          # We had an error when decoding the incoming packets, tell them and close the connection.
          if ($@) {
            debug "Session error, decoding packet. $@";
            my $message = encode_message(warning => {message => $@});
            $stream->write($message);
            $close_session->();
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

              debug Dumper($evalobj);

              if ($prio eq 'deadline') {
                $evalobj->{priority_deadline} = $message->prio->pr_deadline->milliseconds;  
              };

              my $job = $es_self->jobman->add_job($evalobj);
              my $future = $job->{future};
              debug "Got job and future";

              # Log the job for the session. Cancel any in progress with the same sequence.
              if ($es_self->sessions->{$session_id}{jobs}{$sequence}) {
                my $job = $self->sessions->{$session_id}{jobs}{$sequence};
                
                $job->{future}->fail("Session ended") unless $job->{future}->is_ready;
                $job->{canceled} = 1; # Mark them as canceled

                delete $es_self->sessions->{$session_id}{jobs}{$sequence};
              }
              $es_self->sessions->{$session_id}{jobs}{$sequence} = $job;
              
              $future->on_ready(fun ($future) {
                my $output = eval {$future->get()};
                if ($@) {
                  my $response = encode_message(warning => {message => "$@", sequence => $sequence });
                  $stream->write($response);
                } else {
                  my $response = encode_message(response => {sequence => $sequence, contents => $output});
                  $stream->write($response);
                }

                delete $es_self->sessions->{$session_id}{jobs}{$sequence}; # get rid of the references, so we don't leak
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