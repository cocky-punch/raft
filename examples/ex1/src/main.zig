const std = @import("std");
const raft = @import("raft");

const Allocator = std.mem.Allocator;

const MyStateMachine = struct {
    // pub fn apply(self: *@This(), cmd: raft.Command) !void {
    pub fn apply(self: *MyStateMachine, cmd: raft.LogEntry) void {
        // Apply the Raft command (e.g. Set/Delete) to your in-memory state
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

        //FIXME
        // try cluster.registerAddress(entry.id, entry.ip, entry.port);
        _ = entry;
    }

    try cluster.addNode(&node);

    var server = raft.RaftTcpServer(MyStateMachine){
        .allocator = allocator,
        .node = &node,
        .cluster = &cluster,
        .max_clients = 33,
        .active_clients = std.atomic.Value(u32).init(0),
    };

    //FIXME
    // const self_port = blk: {
    //     for (raft_config.nodes) |n| {
    //         if (n.id == raft_config.self_id) break :blk n.port;
    //     }
    //     return error.SelfNodeNotInConfig;
    // };

    // const t = try std.Thread.spawn(.{}, raft.RaftTcpServer(MyStateMachine).start, .{ &server, self_port });
    // FIXME
    const t = try std.Thread.spawn(.{}, raft.RaftTcpServer(MyStateMachine).start, .{ &server, 1234 });
    t.detach();

    // Main loop
    while (true) {
        try cluster.tick();
        // tick to the node every 50ms
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}
