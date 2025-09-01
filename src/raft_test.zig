const std = @import("std");
const testing = std.testing;

const RaftNode = @import("core.zig").RaftNode;
const Cluster = @import("core.zig").Cluster;
const RpcMessage = @import("types.zig").RpcMessage;

// const Command = @import("command.zig").Command;
// const Command = @import("command_v2.zig").Command;
const Command = @import("command_v3.zig").Command;

const StateMachine = @import("state_machine.zig").StateMachine;
const LogEntry = @import("log.zig").LogEntry;

const DummyStateMachine = struct {
    pub fn apply(_: *DummyStateMachine, _: LogEntry) void {
        // No-op
    }

    pub fn queryGet(_: *DummyStateMachine, _: []const u8) []const u8 {
        // No-op
    }
};

test "Follower becomes Candidate on election timeout" {
    const allocator = testing.allocator;
    var dt1 = DummyStateMachine{};
    const sm = StateMachine(DummyStateMachine).init(&dt1);
    var cluster = Cluster(DummyStateMachine).init(allocator);
    defer cluster.deinit();

    //FIXME
    var node = try RaftNode(DummyStateMachine).init(allocator, sm);
    defer node.deinit();

    node.resetElectionTimeout();
    node.state = .Follower;

    node.tick(&cluster);
    try testing.expectEqual(node.state, .Candidate);
}
