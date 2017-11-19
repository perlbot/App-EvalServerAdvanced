package App::EvalServerAdvanced::Seccomp::Plugin::ExecWrapper;

use v5.20;

use strict;
use warnings;
use Function::Parameters;

use App::EvalServerAdvanced::Config;

method init_plugin($class: $seccomp) {
  return; # nothing to do here.
}

method exec_wrapper_gen($seccomp) {
  my @rules;
   for my $language (keys config->language->%* ) {
     my $lang_conf = config->language->$language;

     if ($lang_conf->bin) {
       push @rules, $self->make_rule($lang_conf);
     }
   }

  return @rules;
}

method make_rule($lang_conf) {
  my $strptr = sub {unpack "Q", pack("p", $_[0])};

  return {syscall => 'execve', rules => [[0, '==', $strptr->($lang_conf->{bin})]]};
}

1;

__END__
=pod
=head1 DOCS HERE
=cut
