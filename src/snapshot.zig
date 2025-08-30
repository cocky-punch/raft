const std = @import("std");
const types = @import("types.zig");

pub const SnapshotStorage = struct {
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !SnapshotStorage {
        const dir = try std.fs.cwd().makeOpenPath(path, .{ .iterate = true });
        return SnapshotStorage{ .dir = dir, .allocator = allocator };
    }

    pub fn deinit(self: *SnapshotStorage) void {
        self.dir.close();
    }

    pub fn dumpSnapshotToDisk(self: *SnapshotStorage, snapshot: types.Snapshot) !void {
        const file = try self.dir.createFile("snapshot.bin", .{ .truncate = true });
        defer file.close();

        const writer = file.writer();

        try writer.writeIntLittle(u64, snapshot.last_included_index);
        try writer.writeIntLittle(u64, snapshot.last_included_term);
        try writer.writeAll(snapshot.state_data);
    }

    pub fn restoreSnapshotFromDisk(self: *SnapshotStorage) !types.Snapshot {
        const file = try self.dir.openFile("snapshot.bin", .{});
        defer file.close();

        const reader = file.reader();

        const index = try reader.readIntLittle(u64);
        const term = try reader.readIntLittle(u64);
        const data = try self.allocator.alloc(u8, try file.getEndPos() - 16);
        try reader.readNoEof(data);

        return types.Snapshot{
            .last_included_index = index,
            .last_included_term = term,
            .state_data = data,
        };
    }

    pub fn deleteSnapshotFromDisk(self: *SnapshotStorage) !void {
        try self.dir.deleteFile("snapshot.bin");
    }

    pub fn hasSnapshot(self: *SnapshotStorage) bool {
        return self.dir.access("snapshot.bin", .{}) == null;
    }
};
