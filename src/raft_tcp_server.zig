const std = @import("std");
const RaftNode = @import("raft.zig").RaftNode;
const Cluster = @import("raft.zig").Cluster;
const RpcMessage = @import("types.zig").RpcMessage;

pub fn RaftTcpServer(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        local_node: *RaftNode(T),
        cluster: *Cluster(T),
        max_clients: usize,
        active_clients: std.atomic.Value(u32),
        pending_acks: std.AutoHashMap(u64, std.net.Stream),
        last_checked_log_index: usize = 0,
        next_command_id: std.atomic.Value(u64),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, local_node: *RaftNode(T), cluster: *Cluster(T), max_clients: usize) Self {
            return Self{
                .allocator = allocator,
                .local_node = local_node,
                .cluster = cluster,
                .max_clients = max_clients,
                .pending_acks = std.AutoHashMap(u64, std.net.Stream).init(allocator),
                .active_clients = std.atomic.Value(u32).init(0),
                .next_command_id = std.atomic.Value(u64).init(0),
            };
        }

        pub fn start(self: *Self, port: u16) !void {
            const address = try std.net.Address.parseIp4("127.0.0.1", port);
            var server = try address.listen(.{
                .reuse_address = true,
                .kernel_backlog = 128,
            });
            defer server.deinit();

            std.debug.print("Server listening on: {}\n", .{address});

            while (true) {
                const connection = try server.accept();

                const count = self.active_clients.fetchAdd(1, .seq_cst);
                if (count >= self.max_clients) {
                    //reject a connection
                    _ = self.active_clients.fetchSub(1, .seq_cst);
                    std.log.warn("Client limit reached ({}), rejecting connection", .{self.max_clients});
                    connection.stream.close();
                    continue;
                }

                std.debug.print("New connection from {}\n", .{connection.address});
                _ = try std.Thread.spawn(.{}, handleIncomingConnectionThread, .{ self, connection.stream });
            }
        }

        fn handleIncomingConnectionThread(server: *Self, stream: std.net.Stream) void {
            defer stream.close();
            defer _ = server.active_clients.fetchSub(1, .seq_cst);

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

            std.log.debug("[DEBUG] #1", .{});

            // the counter has advanced its position, hence from 0 again
            try reader.readNoEof(buffer[0..msg_len]);
            std.log.debug("[DEBUG] #2 buffer: {s}", .{buffer[0..msg_len]});

            const msg = try RpcMessage.deserialize(buffer);

            std.log.debug("[DEBUG] #3", .{});

            switch (msg) {
                .ClientCommand => |cmd| {
                    if (self.local_node.state == .Leader) {

                        //TODO
                        //
                        const cmd_id = self.next_command_id.fetchAdd(1, .seq_cst);
                        // const cmd_id = std.crypto.random.int(u64);

                        // const cmd2 = CommandWithId{
                        //     .id = cmd_id,
                        //     .command = cmd, // the Command from the RpcMessage
                        // };

                        try self.pending_acks.put(cmd_id, stream);
                        try self.local_node.handleClientCommand(cmd);
                        // try self.local_node.handleClientCommand(cmd2);
                        // const ack = RpcMessage{ .Ack = .{} };
                        const ack = RpcMessage{ .Ack = .{ .command_id = cmd_id } };

                        try sendFramedRpc(self.allocator, stream.writer(), ack); // reply to client
                    } else {
                        const leader_id = self.local_node.leader_id orelse return error.UnknownLeader;
                        const fallback = RpcMessage{
                            .Redirect = .{ .to = leader_id },
                        };
                        try self.cluster.sendRpc(leader_id, fallback);
                    }
                },
                else => {
                    try self.local_node.enqueueMessage(msg);
                },
            }
        }

        fn deinit(self: *Self) void {
            self.pending_acks.deinit();
        }

        pub fn checkCommittedAcks(self: *Self) !void {
            while (self.last_checked_log_index < self.local_node.commit_index) {
                const entry = self.local_node.log.get(self.last_checked_log_index) orelse break;

                if (entry.command_id) |cmd_id| {
                    if (self.pending_acks.get(cmd_id)) |stream| {
                        const ack_msg = RpcMessage{ .Ack = .{ .command_id = cmd_id } };
                        _ = sendFramedRpc(self.allocator, stream.writer(), ack_msg) catch {};
                        _ = self.pending_acks.remove(cmd_id);
                    }
                }

                self.last_checked_log_index += 1;
            }
        }
    };
}

pub fn sendFramedRpc(allocator: std.mem.Allocator, writer: anytype, msg: RpcMessage) !void {
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
