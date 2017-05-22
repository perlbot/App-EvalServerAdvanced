package EvalServer::Protocol;

use strict;
use warnings;
use Data::Dumper;
use FindBin;
use EvalServer::Log;
use Google::ProtocolBuffers::Dynamic;
use Path::Tiny qw/path/;
# TODO this should be more reliable
my $path = path($FindBin::Bin . "/../lib/EvalServer/protocol.proto");
debug $path->realpath;

# load_file tries to allocate >100TB of ram.  Not sure why.
open(my $fh, "<", $path->realpath);
my $proto = do {local $/; <$fh>};
close($fh);

my $gpb = Google::ProtocolBuffers::Dynamic->new();

$gpb->load_string("protocol.proto", $proto);

$gpb->map({ pb_prefix => "messages", prefix => "EvalServer::Protocol", options => {accessor_style => 'single_accessor'} });

1;