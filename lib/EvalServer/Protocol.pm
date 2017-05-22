package EvalServer::Protocol;

use Google::ProtocolBuffers;
Google::ProtocolBuffers->parse("protocol.protobuf",
    {create_accessors => 1 }
);
 