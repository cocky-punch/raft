const std = @import("std");
const testing = std.testing;

const RaftNode = @import("raft.zig").RaftNode;
const Cluster = @import("raft.zig").Cluster;
const RpcMessage = @import("types.zig").RpcMessage;
const Command = @import("command.zig").Command;
const StateMachine = @import("state_machine.zig").StateMachine;
const LogEntry = @import("log_entry.zig").LogEntry;

const DummyType = struct {};
fn dummyApply(_: *DummyType, _: LogEntry) void {}

test "Follower becomes Candidate on election timeout" {
    const allocator = testing.allocator;
    var dt1 = DummyType{};
    const sm = StateMachine(DummyType).init(&dt1, dummyApply);
    var cluster = Cluster(DummyType).init(allocator);
    defer cluster.deinit();

    var node = try RaftNode(DummyType).init(allocator, 1, sm);
    defer node.deinit();

    node.resetElectionTimeout();
    node.state = .Follower;

    node.tick(&cluster);
    try testing.expectEqual(node.state, .Candidate);
}
