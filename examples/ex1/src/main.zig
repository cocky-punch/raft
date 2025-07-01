const std = @import("std");
const raft = @import("raft");

const Allocator = std.mem.Allocator;
const CLIENTS_MAX_AMOUNT = 50;
const HEARTBEAT_TICK_DURATION_IN_MS = 50;

const MyStateMachine = struct {
    pub fn apply(self: *MyStateMachine, cmd: raft.LogEntry) void {
        std.debug.print("Applied command: {}\n", .{cmd});
        _ = self;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const raft_config = try raft.loadConfig(allocator, "example_raft.yaml");

    // state machine wrapper
    var sm_impl = MyStateMachine{};
    const SM = raft.StateMachine(MyStateMachine);
    const sm = SM{
        .ctx = &sm_impl,
        .apply = MyStateMachine.apply,
    };

    // Init RaftNode and Cluster
    const Node = raft.RaftNode(MyStateMachine);
    const ClusterT = raft.Cluster(MyStateMachine);

    var cluster = ClusterT.init(allocator);
    var node = try Node.init(allocator, raft_config.self_id, sm);

    // Add all node IPs
    for (raft_config.nodes) |entry| {
        try cluster.addNodeAddress(entry.id, entry.address);
    }

    var server = raft.RaftTcpServer(MyStateMachine).init(
        allocator,
        &node,
        &cluster,
        CLIENTS_MAX_AMOUNT,
    );

    const self_port = blk: {
        for (raft_config.nodes) |n| {
            if (n.id == raft_config.self_id) break :blk n.address.port;
        }
        return error.SelfNodeNotInConfig;
    };

    const t = try std.Thread.spawn(.{}, raft.RaftTcpServer(MyStateMachine).start, .{ &server, self_port });
    t.detach();

    // Main loop
    while (true) {
        try cluster.tick();
        // tick to the node every X ms
        std.time.sleep(HEARTBEAT_TICK_DURATION_IN_MS * std.time.ns_per_ms);
    }
}
