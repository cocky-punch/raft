const std = @import("std");
const LogEntry = @import("./log_entry.zig").LogEntry;

pub const RotatingBinaryLog = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    max_entries_per_segment: usize,

    current_file: ?std.fs.File = null,
    current_index: usize = 0,
    current_segment_id: usize = 0,
    current_segment_entry_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        max_entries_per_segment: usize,
    ) RotatingBinaryLog {
        return RotatingBinaryLog{
            .allocator = allocator,
            .dir = dir,
            .max_entries_per_segment = max_entries_per_segment,
        };
    }

    pub fn deinit(self: *RotatingBinaryLog) void {
        if (self.current_file) |file| file.close();
    }

    pub fn append(self: *RotatingBinaryLog, entry: *const LogEntry) !void {
        if (self.current_file == null or self.current_segment_entry_count >= self.max_entries_per_segment) {
            try self.rotateSegment();
        }
        try self.writeBinaryEntry(self.current_file.?, entry);
        self.current_segment_entry_count += 1;
        self.current_index += 1;
    }

    fn rotateSegment(self: *RotatingBinaryLog) !void {
        if (self.current_file) |file| file.close();

        const file_name = try std.fmt.allocPrint(self.allocator, "log.{:08}.bin", .{self.current_segment_id});
        defer self.allocator.free(file_name);

        self.current_file = try self.dir.createFile(file_name, .{});
        self.current_segment_id += 1;
        self.current_segment_entry_count = 0;
    }

    fn writeBinaryEntry(file: std.fs.File, entry: *const LogEntry) !void {
        const writer = file.writer();
        try entry.writeTo(writer);
    }

    pub fn loadAll(self: *RotatingBinaryLog) !std.ArrayList(LogEntry) {
        var entries = std.ArrayList(LogEntry).init(self.allocator);
        var it = self.dir.iterate();
        while (try it.next()) |entry_info| {
            if (!std.mem.startsWith(u8, entry_info.name, "log.")) continue;
            const file = try self.dir.openFile(entry_info.name, .{});
            defer file.close();

            const reader = file.reader();
            while (true) {
                const entry = try LogEntry.readFrom(self.allocator, reader) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                try entries.append(entry);
            }
        }
        return entries;
    }
};
