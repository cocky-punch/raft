const std = @import("std");
const y = @import("yaml");
const types = @import("types.zig");

const RawPeer = struct {
    id: types.NodeId,
    ip: []const u8,
    port: u16,
};

const RawConfig = struct {
    self_id: types.NodeId,
    peers: []const RawPeer,
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !types.RaftConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var parser = y.Yaml{
        .source = content,
    };
    defer parser.deinit(allocator);

    try parser.load(allocator);
    const raw = try parser.parse(allocator, RawConfig);

    const node_list = try allocator.alloc(types.Node, raw.peers.len);
    var self_found = false;

    for (raw.peers, 0..) |peer, i| {
        node_list[i] = types.Node{
            .id = peer.id,
            .address = types.PeerAddress{
                .ip = peer.ip,
                .port = peer.port,
            },
        };
        if (peer.id == raw.self_id) {
            self_found = true;
        }
    }

    if (!self_found) return error.SelfIdNotFound;

    return types.RaftConfig{
        .self_id = raw.self_id,
        .nodes = node_list,
    };
}
