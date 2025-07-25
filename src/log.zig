const std = @import("std");
const LogEntry = @import("log_entry.zig").LogEntry;

pub const Log = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(LogEntry),

    //TODO
    base_index: u64 = 0,
    base_term: u64 = 0,
    // command_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Log {
        return Log{
            .allocator = allocator,
            .entries = std.ArrayList(LogEntry).init(allocator),
        };
    }

    pub fn append(self: *Log, entry: LogEntry) !void {
        try self.entries.append(entry);
    }

    pub fn get(self: *Log, index: usize) ?LogEntry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn lastIndex(self: *Log) usize {
        return if (self.entries.items.len == 0) 0 else self.entries.items.len - 1;
    }

    pub fn termAt(self: *Log, index: usize) ?u64 {
        const entry = self.get(index);
        if (entry) |e| return e.term;
        return null;
    }

    pub fn truncateFrom(self: *Log, start_index: usize) void {
        if (start_index < self.entries.len) {
            self.entries.resize(start_index) catch {};
        }
    }

    pub fn truncate(self: *Log, index: usize) void {
        if (index < self.entries.items.len) {
            self.entries.shrinkRetainingCapacity(index);
        }
        // Else: no-op, nothing to truncate
    }

    pub fn sliceFrom(self: *Log, from_idx: usize) []LogEntry {
        if (from_idx > self.entries.items.len) return &[_]LogEntry{};
        return self.entries.items[from_idx..];
    }

    pub fn replaceWithSnapshotPoint(self: *Log, index: usize, term: usize) !void {
        if (index < self.base_index or index > self.lastIndex()) {
            return error.InvalidSnapshotIndex;
        }

        const pos = index - self.base_index;
        if (pos > self.entries.items.len) {
            return error.InvalidSnapshotIndex;
        }

        const remaining = self.entries.items[pos..];
        var new_entries = try std.ArrayListAligned(LogEntry, null).initCapacity(
            self.entries.allocator,
            remaining.len,
        );
        try new_entries.appendSlice(remaining);

        self.entries.deinit();
        self.entries = new_entries;

        self.base_index = index;
        self.base_term = term;
    }
};

//TODO
// const PersistentLog = struct {
//     file: std.fs.File,
//     allocator: std.mem.Allocator,
//     pub fn append(self: *Self, entry: LogEntry) !void {}
//     pub fn get(self: *Self, index: usize) ?LogEntry {}
//     pub fn loadAll(self: *Self) !void {}
// };
