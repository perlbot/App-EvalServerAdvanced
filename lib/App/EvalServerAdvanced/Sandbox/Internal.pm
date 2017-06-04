package App::EvalServerAdvanced::Sandbox::Internal;
our $VERSION = '0.018';

use strict;
use warnings;

use Module::RunTime qw/require_module check_module_name/;
use Moo;

do { # lexically hide all loading
  my $load_module = sub {
    my ($name) = @_;
    check_module_name($name);

    if ($name !~ /^App::EvalServerAdvanced::Seccomp::Plugin::/) {
      do {
        local @INC = config->sandbox->plugin_base;
        return $name if (eval {require_module($name)});
      };
      # we couldnt' load it from the plugin base, try from @INC with a fully qualified name
      my $fullname = "App::EvalServerAdvanced::Seccomp::Plugin::$name";
      return $fullname if (eval {require_module($fullname)});
      
      die "Failed to find plugin $name";
    } else {
      return $name if (eval {require_module($name)});
      
      die "Failed to find plugin $name";      
    }
  };

  with map {$load_module->($_)} config->sandbox->plugins->@*;
}

1;