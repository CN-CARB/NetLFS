RiceLib.Protobuf.Define("NetLFS.Token", {
    {1, "Token", "string"}
})

RiceLib.Protobuf.Define("NetLFS.File.Receive", {
    {1, "Receiver", "string"},
    {2, "FileID", "string"},
    {3, "FileHash", "string"},
    {4, "AckID", "uint32"}
})

RiceLib.Protobuf.Define("NetLFS.File.NetPayload", {
    {1, "Receiver", "string"},
    {2, "Payload", "bytes", Optional = true, MaxLength = 63e6},
    {3, "AckID", "uint32"}
})

-- Sent back to the sender once the target has handled the file, AckID 0 means no ack requested
RiceLib.Protobuf.Define("NetLFS.File.Ack", {
    {1, "AckID", "uint32"}
})

