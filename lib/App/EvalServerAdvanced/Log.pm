package App::EvalServerAdvanced::Log;
our $VERSION = '0.016';

use strict;
use warnings;
use Function::Parameters;
use App::EvalServerAdvanced::Config;
use Exporter 'import';
our @EXPORT=qw/debug/;

fun debug(@log) {
    return unless config->evalserver->debug;
    my ($package, $file, $line, $sub) = caller 0;
    print STDERR "[${package}::$sub #$line]: ", @log, "\n";
}

1;
