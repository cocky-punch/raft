const std = @import("std");
pub const Command = @import("command.zig").Command;
const LogEntry = @import("log_entry.zig").LogEntry;

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

pub const RaftConfig = struct {
    self_id: NodeId,
    nodes: []const Node, // includes self
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
    Redirect: struct { to: NodeId },
    Ack: struct {},

    pub fn serialize(self: RpcMessage, writer: anytype) !void {
        try std.json.stringify(self, .{}, writer);
    }

    pub fn deserialize(bytes: []const u8) !RpcMessage {
        const parsed = try std.json.parseFromSliceLeaky(RpcMessage, std.heap.page_allocator, bytes, .{});
        return parsed;
    }
};

pub const Snapshot = struct {
    last_included_index: usize,
    last_included_term: usize,
    state_data: []u8, // raw bytes representing the state machine
};

pub const Transport = union(enum) {
    InMemory,
    Tcp,
    // Grpc.
};
