package EvalServer::Config;

use strict;
use warnings;
use TOML;
use FindBin;
use File::Slurper qw/read_text/;

our $config;

sub load_config {
  my $file = $FindBin::Bin."/../etc/config.toml";

  my $data = read_text($file, "utf-8", "auto");

  $config = TOML::from_toml($data);
}

sub config {
  if (!defined $config) {
    load_config();
  };

  return $config;
}

1;
