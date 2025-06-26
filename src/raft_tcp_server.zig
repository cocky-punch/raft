const std = @import("std");
const RaftNode = @import("raft.zig").RaftNode;
const Cluster = @import("cluster.zig").Cluster;
const RpcMessage = @import("types.zig").RpcMessage;

pub fn RaftTcpServer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        node: *RaftNode(T),
        cluster: *Cluster(T),
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, node: *RaftNode(T), cluster: *Cluster(T)) Self {
            return Self{
                .allocator = allocator,
                .node = node,
                .cluster = cluster,
            };
        }

        pub fn start(self: *Self, port: u16) !void {
            var listener = try std.net.StreamServer.listen(.{ .port = port });
            defer listener.deinit();

            while (true) {
                const conn = try listener.accept();
                // optionally spawn a thread or async handler here
                try self.handleIncomingConnection(conn.stream);
            }
        }

        fn handleIncomingConnection(self: *Self, stream: std.net.Stream) !void {
            // const reader = stream.reader();
            // const writer = stream.writer();

            // // Deserialize incoming RpcMessage
            // const msg = try RpcMessage.deserialize(reader); // you'd need to define this

            // // Route to node
            // try self.node.enqueueMessage(msg);

            // // Optional: send a response or ack if needed
            // // writer.writeAll(...) if protocol requires it
            //



            const msg = try RpcMessage.deserialize(stream.reader());
                switch (msg) {
                    .ClientCommand => |cmd| {
                        if (self.node.state == .Leader) {
                            try self.node.handleClientCommand(cmd);
                        } else {
                            const leader_id = self.node.leader_id orelse return;
                            const addr = try self.cluster.node_addresses.get(leader_id) orelse return;
                            var fallback: RpcMessage = .Redirect{ .to = leader_id };
                            try self.cluster.sendRpc(leader_id, fallback);
                        }
                    },
                    else => try self.node.enqueueMessage(msg),
                }
        }
    };
}
