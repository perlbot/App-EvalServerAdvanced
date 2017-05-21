package EvalServer::JobManager;
use v5.24.0;

use strict;
use warnings;
use Data::Dumper;
use Moo;
use EvalServer::Config;
use Function::Parameters;
use POSIX qw/dup2 _exit/;

has loop => (is => 'ro');
has workers => (is => 'ro', builder => sub {[]});
has jobs => (is => 'ro', builder => sub {+{}});

method add_job($eval_obj) {
    my $job = $self->loop->new_future();
    my $prio = $eval_obj->{priority} // "realtime";

    push $self->jobs->{$prio}->@*, {future => $job, eval_obj => $eval_obj};
    $self->tick(); # start anything if possible
    $job->on_ready(sub {$self->tick()}); # try again when this job is over

    return $job;
}

method tick() {
    if ($self->workers->@* < config->jobmanager->max_workers) {
        my $rtcount =()= $self->jobs->{realtime}->@*;
        # TODO implement deadline jobs properly

        for my $prio (qw/realtime deadline batch/) {
            my $candidate = shift $self->jobs->{$prio}->@*;
            next unless $candidate;

            my $job_future = $candidate->{future};
            my $out = '';
            my $in = '';
            my $proc_future = $self->loop->timeout_future(after => config->jobmanager->timeout // 10);
            
            $proc_future->on_ready($job_future)
                        ->on_ready(sub {$proc->kill(15)}); # kill the process

            my $proc = IO::Async::Process->new(
                code => sub {
                    close(STDERR);
                    dup2(1,2) or _exit(212); # Setup the C side of things
                    *STDERR = \*STDOUT; # Setup the perl side of things


                },
                into => \$out,
                from => $in,
                on_finish => sub {$job_future->done($out)}
            );

            return 1;
        }

        return 0; # No jobs found
    } else {
        return 0; # No free workers
    }
}