const std = @import("std");
const RaftNode = @import("raft.zig").RaftNode;
const Cluster = @import("raft.zig").Cluster;
const RpcMessage = @import("types.zig").RpcMessage;
const atomic = std.atomic;

pub fn RaftTcpServer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        node: *RaftNode(T),
        cluster: *Cluster(T),
        max_clients: usize,
        active_clients: atomic.Int,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, node: *RaftNode(T), cluster: *Cluster(T), max_clients: usize) Self {
            return Self{
                .allocator = allocator,
                .node = node,
                .cluster = cluster,
                .max_clients = max_clients,
                .active_clients = atomic.Int.init(0),
            };
        }

        pub fn start(self: *Self, port: u16) !void {
            var listener = try std.net.StreamServer.listen(.{ .port = port });
            defer listener.deinit();

            std.log.info("RaftTcpServer started on port {}", .{port});

            while (true) {
                const conn = try listener.accept();

                const count = self.active_clients.fetchAdd(1, .SeqCst);
                if (count >= self.max_clients) {
                    self.active_clients.fetchSub(1, .SeqCst);
                    std.log.warn("Client limit reached ({}), rejecting connection", .{self.max_clients});
                    conn.stream.close();
                    continue;
                }

                _ = try std.Thread.spawn(.{}, handleIncomingConnectionThread, .{ self, conn.stream });
            }
        }

        fn handleIncomingConnectionThread(server: *Self, stream: std.net.Stream) void {
            defer stream.close();
            defer server.active_clients.fetchSub(1, .SeqCst);

            server.handleIncomingConnection(stream) catch |err| {
                std.log.err("Connection handler failed: {}", .{err});
            };
        }

        pub fn handleIncomingConnection(self: *Self, stream: std.net.Stream) !void {
            var reader = stream.reader();

            // read 4-byte length prefix
            var len_buf: [4]u8 = undefined;
            try reader.readNoEof(&len_buf);
            const msg_len = std.mem.readInt(u32, &len_buf, .big);

            // read that many bytes
            var buffer = try self.allocator.alloc(u8, msg_len);
            defer self.allocator.free(buffer);

            // the counter has advanced its position, hence from 0 again
            try reader.readNoEof(buffer[0..msg_len]);
            const msg = try RpcMessage.deserialize(buffer);

            switch (msg) {
                .ClientCommand => |cmd| {
                    if (self.node.state == .Leader) {
                        try self.node.handleClientCommand(cmd);
                        const ack: RpcMessage = .Ack{};
                        try sendFramedRpc(stream.writer(), ack); // reply to client
                    } else {
                        const leader_id = self.node.leader_id orelse return;
                        const fallback: RpcMessage = .Redirect{ .to = leader_id };
                        try self.cluster.sendRpc(leader_id, fallback);
                    }
                },
                else => {
                    try self.node.enqueueMessage(msg);
                },
            }
        }

        pub fn sendFramedRpc(
            allocator: std.mem.Allocator,
            writer: anytype,
            msg: RpcMessage,
        ) !void {
            var msg_buf = std.ArrayList(u8).init(allocator);
            defer msg_buf.deinit();

            try msg.serialize(msg_buf.writer());

            const msg_bytes = msg_buf.items;
            const msg_len: u32 = @intCast(msg_bytes.len);

            // length prefix
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, msg_len, .big);
            try writer.writeAll(&len_buf);

            // actual message
            try writer.writeAll(msg_bytes);
        }
    };
}
