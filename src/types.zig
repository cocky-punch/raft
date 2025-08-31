const std = @import("std");
pub const Command = @import("command_v3.zig").Command;
const LogEntry = @import("log.zig").LogEntry;

pub const Term = u64;
pub const NodeId = u64;

pub const PeerAddress = struct {
    ip: []const u8,
    port: u16,
};

pub const Node = struct {
    id: NodeId,
    address: PeerAddress,
};

pub const RaftState = enum {
    Follower,
    Candidate,
    Leader,
};

pub const AppendEntries = struct {
    term: Term,
    leader_id: NodeId,
    prev_log_index: usize,
    prev_log_term: Term,
    entries: []LogEntry,
    leader_commit: usize,
};

pub const RequestVote = struct {
    term: Term,
    candidate_id: NodeId,
    last_log_index: usize,
    last_log_term: Term,
};

pub const AppendEntriesResponse = struct {
    term: Term,
    success: bool,
    match_index: usize, // index of the last log entry known to be replicated on follower (if success)
    follower_id: NodeId, // so the leader knows who sent this
};

pub const RequestVoteResponse = struct {
    term: Term,
    vote_granted: bool,
    voter_id: NodeId,
};

pub const InstallSnapshot = struct {
    term: u64,
    leader_id: NodeId,
    last_included_index: usize,
    last_included_term: u64,
    data: []const u8,
};

pub const InstallSnapshotResponse = struct {
    term: u64,
    success: bool,
    follower_id: NodeId,
};

pub const RpcMessage = union(enum) {
    RequestVote: RequestVote,
    RequestVoteResponse: RequestVoteResponse,
    AppendEntries: AppendEntries,
    AppendEntriesResponse: AppendEntriesResponse,

    InstallSnapshot: InstallSnapshot,
    InstallSnapshotResponse: InstallSnapshotResponse,
    TimeoutNow: struct {},

    ClientCommand: Command,
    // ClientCommand: CommandWithId,
    Redirect: struct { to: NodeId },
    Ack: struct { command_id: u64 },

    pub fn serialize(self: RpcMessage, writer: anytype) !void {
        try std.json.stringify(self, .{}, writer);
    }

    pub fn deserialize(bytes: []const u8) !RpcMessage {
        return try std.json.parseFromSliceLeaky(RpcMessage, std.heap.page_allocator, bytes, .{});
    }
};

pub const Snapshot = struct {
    last_included_index: usize,
    last_included_term: usize,
    // raw bytes representing the state machine
    state_data: []u8,
    // if a disk is utilized
    file_path: ?[]const u8,
};

const SnapshotBackend = enum {
    in_memory,
    file,
    // TODO: in the future
    // Sqlite, etc.
};

pub const Transport = union(enum) {
    json_rpc_http: struct {
        use_connection_pooling: bool = true,
        timeout_ms: u32 = 5000,
        max_connections_per_peer: u8 = 5,
    },
    grpc: struct {
        use_connection_pooling: bool = true,
        timeout_ms: u32 = 5000,
        keepalive_ms: u32 = 30000,
    },
    msgpack_tcp: struct {
        use_connection_pooling: bool = true,
        message_framing: MessageFraming = .length_prefixed,
        timeout_ms: u32 = 5000,
        delimiter: ?[]const u8 = null,
    },
    protobuf_tcp: struct {
        use_connection_pooling: bool = true,
        message_framing: MessageFraming = .length_prefixed,
        timeout_ms: u32 = 5000,
    },
    raw_tcp: struct {
        use_connection_pooling: bool = false, // Raw might prefer simple connections
        message_framing: MessageFraming = .length_prefixed,
        timeout_ms: u32 = 5000,
    },
    in_memory: struct {
        simulate_network_delay_ms: ?u32 = null, // For realistic testing
    },

    // TODO: in the future
    // msgpack_udp,
    // protobuf_udp,
};

pub const MessageFraming = enum {
    length_prefixed, // 4 bytes length + payload
    newline_delimited, // For text protocols
    fixed_size, // Fixed message size
    delimiter_based, // Custom delimiter (flexible)
};
