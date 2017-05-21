package EvalServer::Sandbox;

use strict;
use warnings;

use Config;
use Sys::Linux::Namespace;
use Sys::Linux::Mount qw/:all/;
my %sig_map;
use FindBin;
use Path::Tiny qw/path/;
use BSD::Resource;

use EvalServer::Config;
use POSIX qw/_exit/;

do {
  my @sig_names = split ' ', $Config{sig_name}; 
  my @sig_nums = split ' ', $Config{sig_num}; 
  @sig_map{@sig_nums} = map {'SIG' . $_} @sig_names;
  $sig_map{31} = "SIGSYS (Illegal Syscall)";
};

my $namespace = Sys::Linux::Namespace->new(private_pid => 1, no_proc => 1, private_mount => 1, private_uts => 1,  private_ipc => 0, private_sysvsem => 1);

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

  use Carp 'cluck';
  #cluck "run_eval called";

  my @binds = config->sandbox->bind_mounts->@*;

  # these two MUST happen
  push @binds, {src => "../lib", target => "/eval/elib"};
#  unshift @binds, {src => $jail_path, target => "/"};
#  unshift @binds, {src => "/", target => "/"};

	# Get the nobody uid before we chroot, namespace and do other funky stuff.
	my $nobody_uid = getpwnam("nobody");
	die "Error, can't find a uid for 'nobody'. Replace with someone who exists" unless $nobody_uid;

  my $exitcode = $namespace->run(code => sub {
    local $^S=0; # hide the eval that we're in from IPC::Run
    # TODO investigate why this is needed
    $SIG{__DIE__} = sub {print STDERR "e: ", $^S, "\n"; die @_ if $^S; print STDERR @_; _exit(1)};

    for my $bind (@binds) {

      path($jail_path . $bind->{target})->mkpath;
      mount(_rel2abs($bind->{src}), $jail_path . $bind->{target}, undef, MS_BIND|MS_PRIVATE|MS_RDONLY, undef);
    }

    exit(2);

    path("$jail_path/tmp")->mkpath;
    my $tmpfs_size = config->sandbox->tmpfs_size // "16m";
    mount("tmpfs", "$jail_path/tmp", "tmpfs", 0, {size => $tmpfs_size});
    mount("tmpfs", "$jail_path/tmp", "tmpfs", MS_PRIVATE, {size => $tmpfs_size});

    # TODO overlayfs?
    # Path::Tiny->mkpath("$jail_path/tmp/.overlayfs");
    # mount("overlay", "/eval", "overlay", 0, {upper => "/tmp", lower=>"/eval", workdir => "$jail_path/tmp/.overlayfs"})
    print "HELLO WORLD\n";

    chdir($jail_path) or die "Jail was not made"; # ensure it exists before we chroot. unnecessary?
    chroot($jail_path) or die $!;
    chdir(config->sandbox->home_dir // "/tmp") or die "Couldn't chdir to the home";
   
    # TODO move more shit from the wrapper script to here.
    set_resource_limits();

    # TODO Also look at making calls about dropping capabilities(2).  I don't think it's needed but it might be a good idea
    # Here's where we actually drop our root privilege
    $)="$nobody_uid $nobody_uid";
    $(=$nobody_uid;
    $<=$>=$nobody_uid;
    POSIX::setgid($nobody_uid); #We just assume the uid is the same as the gid. Hot.

    die "Failed to drop to nobody"
        if $> != $nobody_uid
        or $< != $nobody_uid;

    my %ENV = config->sandbox->environment->%*; # set the environment up

    # TODO make this unneeded
    #system("/perl5/perlbrew/perls/perlbot-inuse/bin/perl", $filename); 
    #exec($^X, $filename, $language, $code);
    print "Hello World";
  });

  my ($exit, $signal) = (($exitcode&0xFF00)>>8, $exitcode&0xFF);

  if ($exit) {
    print "[Exited $exit]";
  } elsif ($signal) {
    my $signame = $sig_map{$signal} // $signal;
    print "[Died $signame]";
  }

  _exit(0);
}

sub set_resource_limits {
  my %sizes = (
    "t" => 1024 ** 4, # what the hell are you doing needing this?
    "g" => 1024 ** 3,
    "m" => 1024 ** 2,
    "k" => 1024 ** 1,
  );

  my $conv = sub { my ($v, $t)=($_[0] =~ /(\d+)(\w)/); $v * (exists $sizes{lc $t} ? $sizes{lc $t} : 1) };
  my $srl = sub { setrlimit($_[0], $_[1], $_[1]) };

  my $cfg_rlimits = config->sandbox->rlimits;

  $srl->(RLIMIT_VMEM, $conv->($cfg_rlimits->VMEM)) and
  $srl->(RLIMIT_AS, $conv->($cfg_rlimits->AS)) and
  $srl->(RLIMIT_DATA, $conv->($cfg_rlimits->DATA)) and
  $srl->(RLIMIT_STACK, $conv->($cfg_rlimits->STACK)) and
  $srl->(RLIMIT_NPROC, $cfg_rlimits->NPROC) and
  $srl->(RLIMIT_NOFILE, $cfg_rlimits->NOFILE) and
  $srl->(RLIMIT_OFILE, $cfg_rlimits->OFILE) and
  $srl->(RLIMIT_OPEN_MAX, $cfg_rlimits->OPEN_MAX) and
  $srl->(RLIMIT_LOCKS, $cfg_rlimits->LOCKS) and 
  $srl->(RLIMIT_MEMLOCK, $cfg_rlimits->MEMLOCK) and
  $srl->(RLIMIT_CPU, $cfg_rlimits->CPU)
		or die "Failed to set rlimit: $!";
}

1;
