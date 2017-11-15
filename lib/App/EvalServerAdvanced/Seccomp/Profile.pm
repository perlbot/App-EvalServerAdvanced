package App::EvalServerAdvanced::Seccomp::Profile;
use Moo;
use Function::Parameters;

has rules => (is => 'ro', default => sub {[]});
has permutes => (is => 'ro', default => sub {+{}});
has includes => (is => 'ro', default => sub {[]});
has rule_generator => (is => 'ro', predicate => 1);
has name => (is => 'ro');

method get_rules($sandbox) {
  my @rules = map {$sandbox->get_profile_rules($_, $self->name)} $self->includes->@*;
  push @rules, $self->rules->@*;

  if ($self->has_rule_generator()) {
    my ($class, $method) = ($self->rule_generator =~ /^(.*)::([^:]+)$/);

    my $plugin = $sandbox->load_plugin($class);
    push @rules, $plugin->$method($sandbox);
  }

  return @rules;
}

method to_seccomp($sandbox) {
  my @rules = $self->get_rules($sandbox);
  my @seccomp = map {$_->resolve_syscall($sandbox)} @rules;
  return @seccomp;
}

1;
