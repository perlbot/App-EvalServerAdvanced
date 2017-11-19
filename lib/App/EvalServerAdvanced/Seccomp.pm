package App::EvalServerAdvanced::Seccomp;
our $VERSION = '0.021';

use strict;
use warnings;

use v5.20;

use Data::Dumper;
use List::Util qw/reduce uniq/;
use Moo;
#use Linux::Clone;
#use POSIX ();
use Linux::Seccomp;
use Carp qw/croak/;
use Permute::Named::Iter qw/permute_named_iter/;
use Module::Runtime qw/check_module_name require_module module_notional_filename/;
use App::EvalServerAdvanced::Config;
use App::EvalServerAdvanced::ConstantCalc;
use App::EvalServerAdvanced::Seccomp::Profile;
use App::EvalServerAdvanced::Seccomp::Syscall;
use Function::Parameters;
use YAML::XS (); # no imports
use Path::Tiny;

has exec_map => (is => 'ro', default => sub {+{}});
has profiles => (is => 'ro', default => sub {+{}});
has constants => (is => 'ro', default => sub {App::EvalServerAdvanced::ConstantCalc->new()});

has _rules => (is => 'rw');

has _permutes => (is => 'ro', default => sub {+{}});
has _plugins => (is => 'ro', default => sub {+{}});
has _fullpermutes => (is => 'ro', lazy => 1, builder => 'calculate_permutations');
has _used_sets => (is => 'rw', default => sub {+{}});

has _rendered_profiles => (is => 'ro', default => sub {+{}});

has _finalized => (is => 'rw', default => 0); # TODO make this set once

# Define some more open modes that POSIX doesn't have for us.
my ($O_DIRECTORY, $O_CLOEXEC, $O_NOCTTY, $O_NOFOLLOW) = (00200000, 02000000, 00000400, 00400000);

method load_yaml($yaml_file) {

  # TODO sanitize file name via Path::Tiny, ensure it's either in the module location, or next to the sandbox config

  my $input = do {no warnings 'io'; local $/; open(my $fh, "<", $yaml_file); <$fh>};
  my $data = YAML::XS::Load($input);

  if (my $consts = $data->{constants}) {
    for my $const_plugin (($consts->{plugins}//[])->@*) {
      $self->load_plugin("Constants::$const_plugin");
    }

    for my $const_key (keys (($consts->{values}//{})->%*)) {
      $self->constants->add_constant($const_key, $consts->{values}{$const_key})
    }
  }


  for my $profile_key (keys $data->{profiles}->%* ) {
    my $profile_data = $data->{profiles}->{$profile_key};

    my $profile_obj = App::EvalServerAdvanced::Seccomp::Profile->new(%$profile_data);

    $profile_obj->load_permutes($self);
    $self->profiles->{$profile_key} = $profile_obj;
  }

  #print Dumper($data);
}

sub get_profile_rules {
  my ($self, $next_profile, $current_profile) = @_;

  if ($self->_used_sets->{$next_profile}) {
    #warn "Circular reference between $current_profile => $next_profile";
    return (); # short circuit the loop
  }

  $self->_used_sets->{$next_profile} = 1;
  die "No profile found [$next_profile]" unless $self->profiles->{$next_profile};
  return $self->profiles->{$next_profile}->get_rules($self);
}

method build_seccomp() {
  croak "build_seccomp called more than once" if ($self->_finalized);
  $self->_finalized(1);

  for my $profile_key (keys $self->profiles->%*) {
    my $profile_obj = $self->profiles->{$profile_key};

    $self->_used_sets({});
    my @rules = $profile_obj->get_rules($self);
    $self->_rendered_profiles->{$profile_key} = \@rules;
  }
}

sub calculate_permutations {
  my ($self) = @_;
  # TODO this is possible to implement with bitwise checks in seccomp, producing fewer rules.  it should be faster, but is more annoying to implement currently

  my %full_permute;

  for my $permute (keys %{$self->_permutes}) {
    my @modes = @{$self->_permutes->{$permute}} = sort {$a <=> $b} uniq @{$self->_permutes->{$permute}};

    # Produce every bitpattern for this permutation
    for my $bit (1..(2**@modes) - 1) {
      my $q = 1;
      my $mode = 0;
      #printf "%04b: ", $b;
      do {
        if ($q & $bit) {
          my $r = int(log($q)/log(2)+0.5); # get the position

          $mode |= $modes[$r];

          #print "$r";
        }
        $q <<= 1;
      } while ($q <= $bit);

      push $full_permute{$permute}->@*, $mode;
    }
  }

  # This originally sorted the values, why? it shouldn't matter.  must have been for easier sanity checking?
  for my $k (keys %full_permute) {
    $full_permute{$k}->@* = uniq $full_permute{$k}->@*
  }

  return \%full_permute;
}

method apply_seccomp($profile_name) {
  # TODO LOAD the rules

  my $seccomp = Linux::Seccomp->new(SCMP_ACT_KILL);

  for my $rule ($self->_rendered_profiles->{$profile_name}->@* ) {
      # TODO make this support raw syscall numbers?
      my $syscall = $rule->{syscall};
      # If it looks like it's not a raw number, try to resolve.
      $syscall = Linux::Seccomp::syscall_resolve_name($syscall) if ($syscall =~ /\D/);
      my @rules = ($rule->{rules}//[])->@*;

      my %actions = (
        ALLOW => SCMP_ACT_ALLOW,
        KILL  => SCMP_ACT_KILL,
        TRAP  => SCMP_ACT_TRAP,
      );

      my $action = $actions{$rule->{action}//""} // SCMP_ACT_ALLOW;

       if ($rule->{action} && $rule->{action} =~ /^\s*ERRNO\((-?\d+)\)\s*$/ ) { # send errno() to the process
         # TODO, support constants? keys from %! maybe? Errno module?
         $action = SCMP_ACT_ERRNO($1 // -1);
       } elsif ($rule->{action} && $rule->{action} =~ /^\s*TRACE\((-?\d+)?\)\s*$/) { # hit ptrace with msgnum
         $action = SCMP_ACT_TRACE($1 // 0);
       }

      $seccomp->rule_add($action, $syscall, @rules);
  }

  $seccomp->load;
}

method engage($profile_name) {
  $self->build_seccomp();
  $self->apply_seccomp($profile_name);
}

sub load_plugin {
  my ($self, $plugin_name) = @_;

  return $self->_plugins->{$plugin_name} if (exists $self->_plugins->{$plugin_name});

  check_module_name($plugin_name);

  if ($plugin_name !~ /^App::EvalServerAdvanced::Seccomp::Plugin::/) {
    my $plugin;
    if (config->sandbox->plugin_base) { # if we have a plugin base configured, use it first.
      my $plugin_filename = module_notional_filename($plugin_name);
      my $path = path(config->sandbox->plugin_base); # get the only path we'll load short stuff from by it's short name, otherwise deleting a file or a typo could load something we don't want

      my $full_path = $path->child($plugin_filename);

      $plugin = $plugin_name if (eval {require $full_path}); # TODO check if it was a failure to find, or a failure to compile.  failure to compile should still be fatal.
  }

    unless ($plugin) {
      # we couldnt' load it from the plugin base, try from @INC with a fully qualified name
      my $fullname = "App::EvalServerAdvanced::Seccomp::Plugin::$plugin_name";
      $plugin = $fullname if (eval {require_module($fullname)});
      # TODO log errors from module loading
    }

    die "Failed to find plugin $plugin_name" unless $plugin;

    $self->_plugins->{$plugin_name} = $plugin;
    $plugin->init_plugin($self);
    return $plugin;
  } else {
    if (eval {require_module($plugin_name)}) {
      $self->_plugins->{$plugin_name} = $plugin_name;
      $plugin_name->init_plugin($self);
      return $plugin_name;
    }

    die "Failed to find plugin $plugin_name";
  }
}

sub BUILD {
  my ($self) = @_;

#  if (config->sandbox->seccomp->plugins) {
#    for my $plugin_name (config->sandbox->seccomp->plugins->@*) {
#      $self->load_plugin($plugin_name);
#    }
#  }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::EvalServerAdvanced::Seccomp - Use of Seccomp to create a safe execution environment

=head1 VERSION

version 0.001

=head1 DESCRIPTION

This is a rule generator for setting up Linux::Seccomp rules.  It's used internally only, and it's API is not given any consideration for backwards compatibility.  It is however useful to look at the source directly.

=head1 SECURITY

This is an excercise in defense in depths.  The default rulesets
provide a bit of protection against accidentally running knowingly dangerous syscalls.

This does not provide absolute security.  It relies on the fact that the syscalls allowed
are likely to be safe, or commonly required for normal programs to function properly.

In particular there are two syscalls that are allowed that are involved in the Dirty COW
kernel exploit.  C<madvise> and C<mmap>, with these two you can actually trigger the Dirty COW
exploit.  But because the default rules restrict you from creating threads, you can't create the race
condition needed to actually accomplish it.  So you should still take some
other measures to protect yourself.

=head1 AUTHOR

Ryan Voots <simcop@cpan.org>

=cut
