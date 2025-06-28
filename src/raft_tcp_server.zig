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
            var buffer = try self.allocator.alloc(u8, 4096);
            defer self.allocator.free(buffer);

            // Read data from the stream and decode into RpcMessage
            const n = try reader.readAll(buffer);
            const msg = try RpcMessage.deserialize(buffer[0..n]);

            try self.node.enqueueMessage(msg);
        }
    };
}
