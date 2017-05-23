package EvalServer::Protocol;

use strict;
use warnings;
use Data::Dumper;
use FindBin;
use EvalServer::Log;
use Google::ProtocolBuffers::Dynamic;
use Path::Tiny qw/path/;
use Function::Parameters;

# TODO this should be more reliable
my $path = path($FindBin::Bin . "/../lib/EvalServer/protocol.proto");
debug $path->realpath;

# load_file tries to allocate >100TB of ram.  Not sure why.
open(my $fh, "<", $path->realpath);
my $proto = do {local $/; <$fh>};
close($fh);

my $gpb = Google::ProtocolBuffers::Dynamic->new();

$gpb->load_string("protocol.proto", $proto);

$gpb->map({ pb_prefix => "messages", prefix => "ESP", options => {accessor_style => 'single_accessor'} });

fun encode_message($type, $obj) {
    my $message = ESP::Packet->encode({$type => $obj});

    # 8 byte header, 0x0000_0000 0x1234_5678
    # first 4 bytes are reserved for future fuckery, last 4 are length of the message in octets
    my $header = pack "NN", 0, length($message);
    return ($header . $message);
};

fun decode_message($buffer) {
    return (0, undef, undef) if length $buffer < 8; # can't have a message without a header

    my $header = substr($buffer, 0, 8); # grab the header
    my ($reserved, $length) = unpack("NN", $header);

    die "Undecodable message" if ($reserved != 0);
    
    # Packet isn't ready yet
    return (0, undef, undef) if (length($buffer) - 8 < $length);

    my $message_bytes = substr($buffer, 8, $length);
    substr($buffer, 0, $length+8, "");

    my $message = ESP::Packet->decode($message_bytes);
    my ($k) = keys %$message;

    return (1, $message->$k, $buffer);
};

1;