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
use Module::Runtime qw/check_module_name require_module/;
use App::EvalServerAdvanced::Config;
use App::EvalServerAdvanced::ConstantCalc;
use App::EvalServerAdvanced::Seccomp::Profile;
use App::EvalServerAdvanced::Seccomp::Syscall;
use Function::Parameters;
use YAML::XS (); # no imports

# use constant {
#   CLONE_FILES => Linux::Clone::FILES,
#   CLONE_FS => Linux::Clone::FS,
#   CLONE_NEWNS => Linux::Clone::NEWNS,
#   CLONE_VM => Linux::Clone::VM,
#   CLONE_THREAD => Linux::Clone::THREAD,
#   CLONE_SIGHAND => Linux::Clone::SIGHAND,
#   CLONE_SYSVSEM => Linux::Clone::SYSVSEM,
#   CLONE_NEWUSER => Linux::Clone::NEWUSER,
#   CLONE_NEWPID => Linux::Clone::NEWPID,
#   CLONE_NEWUTS => Linux::Clone::NEWUTS,
#   CLONE_NEWIPC => Linux::Clone::NEWIPC,
#   CLONE_NEWNET => Linux::Clone::NEWNET,
#   CLONE_NEWCGROUP => Linux::Clone::NEWCGROUP,
#   CLONE_PTRACE => Linux::Clone::PTRACE,
#   CLONE_VFORK => Linux::Clone::VFORK,
#   CLONE_SETTLS => Linux::Clone::SETTLS,
#   CLONE_PARENT_SETTID => Linux::Clone::PARENT_SETTID,
#   CLONE_CHILD_SETTID => Linux::Clone::CHILD_SETTID,
#   CLONE_CHILD_CLEARTID => Linux::Clone::CHILD_CLEARTID,
#   CLONE_DETACHED => Linux::Clone::DETACHED,
#   CLONE_UNTRACED => Linux::Clone::UNTRACED,
#   CLONE_IO => Linux::Clone::IO,
# };

has exec_map => (is => 'ro', default => sub {+{}});
has profiles => (is => 'ro', default => sub {+{}});
has constants => (is => 'ro', default => sub {App::EvalServerAdvanced::ConstantCalc->new()});

has _rules => (is => 'rw');

has seccomp => (is => 'ro', default => sub {Linux::Seccomp->new(SCMP_ACT_KILL)});
has _permutes => (is => 'ro', default => sub {+{}});
has _plugins => (is => 'ro', default => sub {+{}});
has _fullpermutes => (is => 'ro', lazy => 1, builder => 'calculate_permutations');
has _used_sets => (is => 'ro', default => sub {+{}});

has _finalized => (is => 'rw', default => 0); # TODO make this set once

# Define some more open modes that POSIX doesn't have for us.
my ($O_DIRECTORY, $O_CLOEXEC, $O_NOCTTY, $O_NOFOLLOW) = (00200000, 02000000, 00000400, 00400000);


#   # exec wrapper
#   exec_wrapper => {
#     # we have to generate these at runtime, we can't know ahead of time what they will be
#     rules => sub {
#         my $seccomp = shift;
#         my $strptr = sub {unpack "Q", pack("p", $_[0])};
#         my @rules;
#
#         my $exec_map = $seccomp->exec_map;
#
#         for my $version (keys %$exec_map) {
#           push @rules, {syscall => 'execve', rules => [[0, '==', $strptr->($exec_map->{$version}{bin})]]};
#         }
#
#         return @rules;
#       }, # sub returns a valid arrayref.  given our $self as first arg.
#   },

method load_yaml($yaml_file) {

  # TODO sanitize file name via Path::Tiny, ensure it's either in the module location, or next to the sandbox config

  my $data = YAML::XS::LoadFile($yaml_file);

  if (my $consts = $data->{constants}) {
    for my $const_plugin (($consts->{plugins}//[])->@*) {
      $self->load_plugin("Constants::$const_plugin");
    }

    for my $const_key (keys (($consts->{values}//{})->%*)) {
      $self->constants->add_constant($const_key, $consts->{values}{$const_key})
    }
  }

  print Dumper($data);
}

sub get_profile_rules {
  my ($self, $next_profile, $current_profile) = @_;

  if ($self->_used_sets->{$next_profile}) {
    #warn "Circular reference between $current_profile => $next_profile";
    return (); # short circuit the loop
  }

  $self->_used_sets->{$next_profile} = 1;
  return $self->profiles->{$next_profile}->get_rules;
}

sub rule_add {
  my ($self, $name, @rules) = @_;
  # TODO make this support raw syscall numbers?
  $self->seccomp->rule_add(SCMP_ACT_ALLOW, Linux::Seccomp::syscall_resolve_name($name), @rules);
}

# sub _rec_get_rules {
#   my ($self, $profile) = @_;
# 
#   return () if ($self->_used_sets->{$profile});
#   $self->_used_sets->{$profile} = 1;
# 
#   croak "Rule set $profile not found" unless exists $rule_sets{$profile};
# 
#   my @rules;
#   #print "getting profile $profile\n";
# 
#   if (ref $rule_sets{$profile}{rules} eq 'ARRAY') {
#     push @rules, @{$rule_sets{$profile}{rules}};
#   } elsif (ref $rule_sets{$profile}{rules} eq 'CODE') {
#     my @sub_rules = $rule_sets{$profile}{rules}->($self);
#     push @rules, @sub_rules;
#   } elsif (!exists $rule_sets{$profile}{rules}) { # ignore it if missing
#   } else {
#     croak "Rule set $profile defines an invalid set of rules";
#   }
# 
#   for my $perm (keys %{$rule_sets{$profile}{permute} // +{}}) {
#     push @{$self->_permutes->{$perm}}, @{$rule_sets{$profile}{permute}{$perm}};
#   }
# 
#   for my $include (@{$rule_sets{$profile}{include}//[]}) {
#     push @rules, $self->_rec_get_rules($include);
#   }
# 
#   return @rules;
# }

sub build_seccomp {
  my ($self) = @_;

  croak "build_seccomp called more than once" if ($self->_finalized);
  $self->_finalized(1);

  my %gathered_rules; # computed rules

  for my $profile (@{$self->profiles}) {
    my @rules = $self->_rec_get_rules($profile);

    for my $rule (@rules) {
      my $syscall = $rule->{syscall};
      push @{$gathered_rules{$syscall}}, $rule;
    }
  }

  my %comp_rules;

  for my $syscall (keys %gathered_rules) {
    my @rules = @{$gathered_rules{$syscall}};
    for my $rule (@rules) {
      my $syscall = $rule->{syscall};

      if (exists ($rule->{permute_rules})) {
        my @perm_on = ();
        for my $prule (@{$rule->{permute_rules}}) {
          if (ref $prule->[2]) {
            push @perm_on, ${$prule->[2]};
          }
          if (ref $prule->[0]) {
            croak "Permuation on argument number not supported using $syscall";
          }
        }

        croak "Permutation on syscall rule without actual permutation specified" if (!@perm_on);

        my %perm_hash = map {$_ => $self->_fullpermutes->{$_}} @perm_on;
        my $iter = permute_named_iter(%perm_hash);

        while (my $pvals = $iter->()) {

          push @{$comp_rules{$syscall}},
            [map {
              my @r = @$_;
              $r[2] = $pvals->{${$r[2]}};
              \@r;
            } @{$rule->{permute_rules}}];
        }
      } elsif (exists ($rule->{rules})) {
        push @{$comp_rules{$syscall}}, $rule->{rules};
      } else {
        push @{$comp_rules{$syscall}}, [];
      }
    }
  }

  # TODO optimize for permissive rules
  # e.g. write => OR write => [0, '==', 1] OR write => [0, '==', 2] becomes write =>
  for my $syscall (keys %comp_rules) {
    for my $rule (@{$comp_rules{$syscall}}) {
      $self->rule_add($syscall, @$rule);
    }
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

sub apply_seccomp {
  my $self = shift;
  $self->seccomp->load;
}

sub engage {
  my $self = shift;
  $self->build_seccomp();
  $self->apply_seccomp();
}

sub load_plugin {
  my ($self, $plugin_name) = @_;

  return $self->_plugins->{$plugin_name} if (exists $self->_plugins->{$plugin_name});

  check_module_name($plugin_name);

  if ($plugin_name !~ /^App::EvalServerAdvanced::Seccomp::Plugin::/) {
    my $plugin;
    do {
      local @INC = config->sandbox->plugin_base;
      $plugin = $plugin_name if (eval {require_module($plugin_name)});
      # TODO log errors from loading?
    };

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

  if (config->sandbox->seccomp->plugins) {
    for my $plugin_name (config->sandbox->seccomp->plugins->@*) {
      $self->load_plugin($plugin_name);
    }
  }
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

This is a rule generator for setting up Linux::Seccomp rules.

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
