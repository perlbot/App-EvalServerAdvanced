package App::EvalServerAdvanced::Seccomp::Syscall;
use Moo;
use Function::Parameters;

has syscall => (is => 'ro');
has tests => (is => 'ro');

# take the test and return however many seccomp rules it needs.  doing any permutated arguments, and looking up of constants
method resolve_syscall($seccomp) {
  my $permutations = $seccomp->_fullpermutes;

  my @rendered_tests;

  for my $test ($self->tests->@* ) {
    my ($arg, $operator, $value) = $test->@*;

    # If it has any non-digit characters, assume it needs to be calculated from constants, or permuted
    if ($value =~ /^\s*\{\{\s*(.*)\s*\}\}\s*$/) {
      my $permuted_name = $1;

      # permutation values get calculated already
      push @rendered_tests, map {[$arg, $operator, $_]} $permutations->{$permuted_name};
    } elsif ($value =~ /\D/) {
      push @rendered_tests, [$arg, $operator, $seccomp->constants->get_value($value)];
    } else { # We're a simple test, we just go straight through.
      push @rendered_tests, $test;
    }
  }

  return {syscall => $self->syscall, rules => \@rendered_tests};
}

# TODO importable API to aid in syscall rule creation

1;
