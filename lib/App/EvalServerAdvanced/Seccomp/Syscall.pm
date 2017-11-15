package App::EvalServerAdvanced::Seccomp::Syscall;
use Moo;
use Function::Parameters;

has name => (is => 'ro');
has tests => (is => 'ro');

# take the test and return however many seccomp rules it needs.  doing any permutated arguments, and looking up of constants
method resolve_syscall($sandbox) {
  my $constants = $sandbox->get_constants;
  my $permutations = $sandbox->get_permutations;

  my @rendered_tests;

  for my $test ($self->tests->@* ) {
    my ($arg, $operator, $value) = $test->@*;

    # If it has any non-digit characters, assume it needs to be calculated from constants, or permuted
    if ($value =~ /\{\{\s*(.*)\s*\}\}/) {
      my $permuted_name = $1;
    } elsif ($value =~ /\D/) {
      push @rendered_tests, [$arg, $operator, $self->calculate_constants($value)];
    } else { # We're a simple test, we just go straight through.
      push @rendered_tests, $test;
    }
  }
}

# TODO importable API to aid in syscall rule creation

1;
