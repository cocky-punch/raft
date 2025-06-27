//FIXME: merge with types.Node, types.RaftConfig

pub const Peer = struct {
    id: u64,
    ip: []const u8,
    port: u16,
};

pub const Config = struct {
    self: Peer,
    peers: []Peer,
};
