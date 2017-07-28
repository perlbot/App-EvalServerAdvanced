package App::EvalServerAdvanced::Seccomp::Plugin::Perlbot;
use strict;
use warnings;

use Moo;
extends 'App::EvalServerAdvanced::Seccomp::Plugin';

sub define_ruleset {
  my ($self, $seccomp) = @_;

  $seccomp->add_ruleset(lang_perlbot => {
      rules => [],
      include => [],
    });

  $seccomp->ruleset();
}

1;
__END__
