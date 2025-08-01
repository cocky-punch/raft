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

    // Parse command-line args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var config_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        }
    }

    const raft_config_path = config_path orelse return error.MissingConfigArgument;
    const raft_config = try raft.loadConfig(allocator, raft_config_path);

    // state machine wrapper
    var sm_impl = MyStateMachine{};
    const SM = raft.StateMachine(MyStateMachine);
    const sm = SM{
        .ctx = &sm_impl,
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
        try server.checkCommittedAcks(); // sends acks to clients if commit_index advanced
        // tick to the node every X ms
        std.time.sleep(HEARTBEAT_TICK_DURATION_IN_MS * std.time.ns_per_ms);
    }
}
