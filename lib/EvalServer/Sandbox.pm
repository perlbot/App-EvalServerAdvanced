package EvalServer::Sandbox;

use strict;
use warnings;

use Config;
use Sys::Linux::Namespace;
use Sys::Linux::Mount qw/:all/;
my %sig_map;
use FindBin;

use EvalServer::Config;

do {
  my @sig_names = split ' ', $Config{sig_name}; 
  my @sig_nums = split ' ', $Config{sig_num}; 
  @sig_map{@sig_nums} = map {'SIG' . $_} @sig_names;
  $sig_map{31} = "SIGSYS (Illegal Syscall)";
};

my $namespace = Sys::Linux::Namespace->new(private_pid => 1, no_proc => 1, private_mount => 1, private_uts => 1,  private_ipc => 0, private_sysvsem => 1);

# {files => [
#      {filename => '...',
#       contents => '...',},
#       ...,],
#  main_file => 'filename',
#  main_language => '',
# }
#

sub _rel2abs {
  my $p = shift;
  if ($p !~ m|^/|) {
    $p = "$FindBin::Bin/$p";
  }
  return $p
}

sub run_eval {
  my $code = shift; # TODO this should be more than just code
  my $language = shift;
  my $files = shift;
  my $jail_path = Path::Tiny->tempdir;
  my $jail_root_path = _rel2abs config->sandbox->jail_root // die "No path provided for jail";

	my $filename = '/eval/elib/eval.pl';

  my @binds = config->sandbox->bind_mounts->@*;

  $namespace->run(code => sub {
    my $home = "/";
    for my $bind (@binds) {
      mount(_rel2abs $bind->{src}, $jail_path . $bind->{target}, undef, MS_BIND|MS_PRIVATE|MS_RDONLY, undef);
      $home = $bind->{target} if $bind->{is_home};
    }

    mount("tmpfs", "$jail_path/tmp", "tmpfs", 0, {size => config->sandbox->tmpfs_size});
    mount("tmpfs", "$jail_path/tmp", "tmpfs", MS_PRIVATE, {size => config->sandbox->tmpfs_size});

    chdir($jail_path) or die "Jail not made, see bin/makejail.sh";
    chroot($jail_path) or die $!;
    chdir($home) or die "Couldn't chdir to $home";
   
    # TODO move more shit from the wrapper script to here.

    #system("/perl5/perlbrew/perls/perlbot-inuse/bin/perl", $filename); 
    system($^X, $filename, $language, $code); 
    my ($exit, $signal) = (($?&0xFF00)>>8, $?&0xFF);

    if ($exit) {
     print "[Exited $exit]";
    } elsif ($signal) {
     my $signame = $sig_map{$signal} // $signal;
     print "[Died $signame]";
    }
  });
}

sub set_resource_limits {
}

1;
