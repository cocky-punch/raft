const std = @import("std");
const testing = std.testing;

const RaftNode = @import("core.zig").RaftNode;
const Cluster = @import("core.zig").Cluster;
const RpcMessage = @import("types.zig").RpcMessage;
const Command = @import("command.zig").Command;
const StateMachine = @import("state_machine.zig").StateMachine;
const LogEntry = @import("log.zig").LogEntry;
const cfg = @import("config.zig");

const DummyStateMachine = struct {
    pub fn apply(_: *DummyStateMachine, _: LogEntry) void {
        // No-op
    }

    pub fn queryGet(_: *DummyStateMachine, _: []const u8) []const u8 {
        // No-op
    }
};

test "Follower becomes Candidate on election timeout, on in-memory transport" {
    const allocator = testing.allocator;
    var dt1 = DummyStateMachine{};
    const sm = StateMachine(DummyStateMachine).init(&dt1);
    var cluster = Cluster(DummyStateMachine).init(allocator);
    defer cluster.deinit();

    const cfg1 = cfg.Config.parseFromString(allocator,
        \\self_id: 1
        \\
        \\peers:
        \\  - id: 1
        \\    ip: "127.0.0.1"
        \\    port: 9001
        \\
        \\  - id: 2
        \\    ip: "127.0.0.1"
        \\    port: 9002
        \\
        \\  - id: 3
        \\    ip: "127.0.0.1"
        \\    port: 9003
        \\
        \\  - id: 4
        \\    ip: "127.0.0.1"
        \\    port: 9004
        \\
        \\  - id: 5
        \\    ip: "127.0.0.1"
        \\    port: 9005
        \\
        \\protocol:
        \\  election_timeout_min_ms: 150
        \\  heartbeat_interval_ms: 50
        \\  max_entries_per_append: 100
        \\  storage_type: "in_memory"
        \\  leader_lease_timeout_ms: 150
        \\
        \\transport:
        \\  type: "in_memory"
        \\  in_memory:
        \\    simulate_network_delay_ms: 1000
        \\
        \\client:
        \\  read_consistency: "linearizable"
        \\  client_timeout_ms: 5000
        \\
        \\performance:
        \\  batch_append_entries: true
        \\  pre_vote_enabled: true
        \\
    ) catch |err| {
        std.debug.print("Failed to parse config: {}\n", .{err});
        return;
    };

    var node = try RaftNode(DummyStateMachine).init(allocator, .{ .config = cfg1 }, sm);
    defer node.deinit();

    node.state = .Follower;
    node.resetElectionTimeout();

    // still a follower
    try testing.expectEqual(node.state, .Follower);

    // Wait for the election timeout to expire (150ms minimum + some buffer)
    std.Thread.sleep(350 * std.time.ns_per_ms);

    // now process the timeout
    node.processInMemoryData(&cluster);

    try testing.expectEqual(node.state, .Candidate);
}
