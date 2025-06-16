const std = @import("std");

const LogEntry = @import("log_entry.zig").LogEntry;
pub const Term = u64;
pub const NodeId = u32;
pub const Node = struct {
    id: NodeId,
    address: []const u8, // or IP/port tuple, depending on your message transport
};

pub const RaftConfig = struct {
    self_id: NodeId,
    nodes: []const Node, // list of known peers (including self)
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
};
