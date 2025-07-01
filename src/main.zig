const std = @import("std");
const raft = @import("raft.zig");
const RaftNode = raft.RaftNode;
const LogEntry = @import("log_entry.zig").LogEntry;
const cfg = @import("config.zig");

const MySM = struct {
    pub fn apply(self: *MySM, entry: LogEntry) void {
        std.debug.print("Applying entry: {}\n", .{entry});
        _ = self;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Define concrete types based on MySM
    var sm_ctx = MySM{};
    const SM = raft.StateMachine(MySM);

    const sm1 = SM{
        .ctx = &sm_ctx,
        .apply = MySM.apply,
    };

    const Node = raft.RaftNode(MySM);
    const ClusterT = raft.Cluster(MySM);

    var cluster = ClusterT.init(allocator);
    var node1 = try Node.init(allocator, 1, sm1);
    var node2 = try Node.init(allocator, 2, sm1);
    var node3 = try Node.init(allocator, 3, sm1);

    try cluster.addNode(&node1);
    try cluster.addNode(&node2);
    try cluster.addNode(&node3);

    //
    //TODO real network transport
    //
    const raft_config = try cfg.loadConfig(allocator, "example_raft.yaml");

    // for (raft_config.peers) |p| {
    // try cluster.node_addresses.put(p.id, p);
    // std.debug.print("p: {}\n", .{p});
    // }

    for (raft_config.nodes) |nd| {
        // try cluster.node_addresses.put(nd.id, nd);
        std.debug.print("node: {}\n", .{nd});
    }

    const tick_interval = 50; // milliseconds
    while (true) {
        try cluster.tick();
        // try node.processMessages(&cluster);

        std.time.sleep(tick_interval * std.time.ns_per_ms);
    }
}
