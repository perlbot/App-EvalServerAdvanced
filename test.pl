#!/usr/bin/env perl

use strict;
use warnings;
use IPC::Run qw/harness/;

use Data::Dumper;
use POSIX qw/_exit/;

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
  my $h = harness sub {$|++; print "HI\n"; _exit(0);}, '<', \$in, '>&', \$out;
  my ($start_time, $end_time);
  eval {
    $h->start();
    $start_time = time();
    while($h->pumpable()) {
      $h->pump_nb();

      sleep(0.1); # yield some time
      die "Timeout" if (time() - $start_time) > 12;
    }
  };
  $end_time = time();
  my $err = $@;
  $h->kill_kill; # shouldn't be necessary but it's safe
  eval {$h->finish();} if $err;

  print STDERR Dumper({out => $out, pid => $$, opid => $origpid});

  return "poop $out";  
}

worker({files => {__code => "..."}, lang => "perl"});
