const std = @import("std");
const raft = @import("raft");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: cli <ip> <port> <set|delete> <key> [value]\n", .{});
        return;
    }

    const ip = args[1];
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const cmd_type = args[3];
    const key = args[4][0..];
    const value = if (args.len > 5) args[5][0..] else "";

    var stream = try std.net.tcpConnectToHost(allocator, ip, port);
    defer stream.close();

    const key_owned = try allocator.dupe(u8, key);
    const value_owned = try allocator.dupe(u8, value);

    std.log.debug("[DEBUG] [cli] cmd_type: {s}; key_owned: {s}; value_owned: {s}", .{ cmd_type, key_owned, value_owned });

    const msg = if (std.mem.eql(u8, cmd_type, "set")) raft.RpcMessage{
        .ClientCommand = raft.Command{ .Set = .{ .key = key_owned, .value = value_owned } },
    } else if (std.mem.eql(u8, cmd_type, "delete")) raft.RpcMessage{
        .ClientCommand = raft.Command{ .Delete = .{ .key = key_owned } },
    } else return error.InvalidCommand;

    std.log.debug("[DEBUG] [cli] msg: {}", .{msg});

    try raft.sendFramedRpc(allocator, stream.writer(), msg);
    var reader = stream.reader();
    var buf: [4096]u8 = undefined;
    const n = try reader.readAll(&buf);
    std.debug.print("Response: {s}\n", .{buf[0..n]});
}
