const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const crc32 = std.hash.crc.Crc32;
const Command = @import("command_v3.zig").Command;

pub const LogConfig = struct {
    storage_type: enum { memory, persistent },
    data_dir: ?[]const u8 = null,
};

pub const LogEntry = struct {
    term: u64,
    index: u64,
    data: []const u8,
    command: ?Command = null, // Optional structured command
    const Self = @This();

    pub fn serialize(self: *const LogEntry, writer: std.fs.File.Writer) !void {
        try writer.writeInt(u64, self.term, .little);
        try writer.writeInt(u64, self.index, .little);
        try writer.writeInt(u64, self.data.len, .little);
        try writer.writeAll(self.data);
    }

    pub fn deserialize(allocator: Allocator, reader: anytype) !LogEntry {
        const term = try reader.readInt(u64, .little);
        const index = try reader.readInt(u64, .little);
        const data_len = try reader.readInt(u64, .little);

        const data = try allocator.alloc(u8, data_len);
        try reader.readNoEof(data);

        return LogEntry{
            .term = term,
            .index = index,
            .data = data,
        };
    }

    // Create LogEntry from command (new API)
    pub fn fromCommand(allocator: Allocator, term: u64, index: u64, command: Command) !Self {
        const data = try command.toRawData(allocator);

        return Self{
            .term = term,
            .index = index,
            .data = data,
            .command = command,
        };
    }
};

// Persistent state that must survive crashes
pub const PersistentState = struct {
    current_term: u64,
    voted_for: ?u32, // node_id or null

    pub fn serialize(self: *const PersistentState, writer: anytype) !void {
        try writer.writeInt(u64, self.current_term, .little);
        const has_vote = self.voted_for != null;
        try writer.writeByte(if (has_vote) 1 else 0);
        if (has_vote) {
            try writer.writeInt(u32, self.voted_for.?, .little);
        }
    }

    pub fn deserialize(reader: anytype) !PersistentState {
        const current_term = try reader.readInt(u64, .little);
        const has_vote = (try reader.readByte()) != 0;
        const voted_for = if (has_vote) try reader.readInt(u32, .little) else null;

        return PersistentState{
            .current_term = current_term,
            .voted_for = voted_for,
        };
    }
};

// WAL Record types
pub const WALRecordType = enum(u8) {
    append_entry = 1,
    truncate_from = 2,
    update_term = 3,
    set_voted_for = 4,
    checkpoint = 5,
};

pub const WALRecord = struct {
    record_type: WALRecordType,
    data: union {
        append_entry: LogEntry,
        truncate_from: u64,
        update_term: u64,
        set_voted_for: ?u32,
        checkpoint: void,
    },

    pub fn serialize(self: *const WALRecord, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self.record_type));

        switch (self.record_type) {
            .append_entry => try self.data.append_entry.serialize(writer),
            .truncate_from => try writer.writeInt(u64, self.data.truncate_from, .little),
            .update_term => try writer.writeInt(u64, self.data.update_term, .little),
            .set_voted_for => {
                const has_vote = self.data.set_voted_for != null;
                try writer.writeByte(if (has_vote) 1 else 0);
                if (has_vote) {
                    try writer.writeInt(u32, self.data.set_voted_for.?, .little);
                }
            },
            .checkpoint => {}, // No data for checkpoint
        }
    }

    //old
    // pub fn deserialize(allocator: Allocator, reader: anytype) !WALRecord {
    //     const record_type_raw = try reader.readByte();
    //     const record_type = @as(WALRecordType, @enumFromInt(record_type_raw));

    //     var record = WALRecord{
    //         .record_type = record_type,
    //         .data = undefined,
    //     };

    //     switch (record_type) {
    //         .append_entry => {
    //             record.data = .{ .append_entry = try LogEntry.deserialize(allocator, reader) };
    //         },
    //         .truncate_from => {
    //             record.data = .{ .truncate_from = try reader.readInt(u64, .little) };
    //         },
    //         .update_term => {
    //             record.data = .{ .update_term = try reader.readInt(u64, .little) };
    //         },
    //         .set_voted_for => {
    //             const has_vote = (try reader.readByte()) != 0;
    //             const voted_for = if (has_vote) try reader.readInt(u32, .little) else null;
    //             record.data = .{ .set_voted_for = voted_for };
    //         },
    //         .checkpoint => {
    //             record.data = .{ .checkpoint = {} };
    //         },
    //     }

    //     return record;
    // }


    //new, zig v0.15
    pub fn deserialize(allocator: Allocator, reader: anytype) !WALRecord {
        // Read a single byte for record type
        var byte_buffer: [1]u8 = undefined;
        _ = try reader.read(&byte_buffer);
        const record_type_raw = byte_buffer[0];
        const record_type = @as(WALRecordType, @enumFromInt(record_type_raw));

        var record = WALRecord{
            .record_type = record_type,
            .data = undefined,
        };

        switch (record_type) {
            .append_entry => {
                record.data = .{ .append_entry = try LogEntry.deserialize(allocator, reader) };
            },
            .truncate_from => {
                // Read 8 bytes for u64 in little endian
                var int_buffer: [8]u8 = undefined;
                _ = try reader.read(&int_buffer);
                const value = std.mem.readInt(u64, &int_buffer, .little);
                record.data = .{ .truncate_from = value };
            },
            .update_term => {
                // Read 8 bytes for u64 in little endian
                var int_buffer: [8]u8 = undefined;
                _ = try reader.read(&int_buffer);
                const value = std.mem.readInt(u64, &int_buffer, .little);
                record.data = .{ .update_term = value };
            },
            .set_voted_for => {
                // Read has_vote flag
                var byte_buffer2: [1]u8 = undefined;
                _ = try reader.read(&byte_buffer2);
                const has_vote = byte_buffer2[0] != 0;

                const voted_for = if (has_vote) blk: {
                    // Read 4 bytes for u32 in little endian
                    var int_buffer: [4]u8 = undefined;
                    _ = try reader.read(&int_buffer);
                    break :blk std.mem.readInt(u32, &int_buffer, .little);
                } else null;

                record.data = .{ .set_voted_for = voted_for };
            },
            .checkpoint => {
                record.data = .{ .checkpoint = {} };
            },
        }
        return record;
    }
};

pub const PersistentLog = struct {
    allocator: Allocator,
    log_file: std.fs.File,
    state_file: std.fs.File,
    wal_file: std.fs.File,
    entries: ArrayList(LogEntry),
    persistent_state: PersistentState,
    wal_buffer: ArrayList(WALRecord),
    last_checkpoint_pos: u64,

    const LOG_FILE_NAME = "raft_log.dat";
    const STATE_FILE_NAME = "raft_state.dat";
    const WAL_FILE_NAME = "raft_wal.dat";
    const MAGIC_HEADER: u32 = 0x52414654; // "RAFT"
    const WAL_BUFFER_SIZE = 1000; // Max records before forced flush

    pub fn init(allocator: Allocator, data_dir: []const u8) !PersistentLog {
        // Create data directory if it doesn't exist
        std.fs.cwd().makeDir(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var dir = try std.fs.cwd().openDir(data_dir, .{});
        defer dir.close();

        // Open or create log file
        const log_file = dir.createFile(LOG_FILE_NAME, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(LOG_FILE_NAME, .{ .mode = .read_write }),
            else => return err,
        };

        // Open or create state file
        const state_file = dir.createFile(STATE_FILE_NAME, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(STATE_FILE_NAME, .{ .mode = .read_write }),
            else => return err,
        };

        // Open or create WAL file
        const wal_file = dir.createFile(WAL_FILE_NAME, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(WAL_FILE_NAME, .{ .mode = .read_write }),
            else => return err,
        };

        var persistent_log = PersistentLog{
            .allocator = allocator,
            .log_file = log_file,
            .state_file = state_file,
            .wal_file = wal_file,

            // .entries = ArrayList(LogEntry).init(allocator),
            .entries = .empty,

            .persistent_state = PersistentState{ .current_term = 0, .voted_for = null },

            // .wal_buffer = ArrayList(WALRecord).init(allocator),
            .wal_buffer = .empty,


            .last_checkpoint_pos = 0,
        };

        // Recovery process: replay WAL first, then load checkpoint data
        try persistent_log.recoverFromWAL();
        try persistent_log.loadState();
        try persistent_log.loadLog();

        return persistent_log;
    }

    pub fn deinit(self: *PersistentLog) void {
        // Flush any pending WAL records
        self.flushWAL() catch {};

        // Free allocated entry data
        for (self.entries.items) |entry| {
            self.allocator.free(entry.data);
        }

        // Free WAL buffer data
        for (self.wal_buffer.items) |record| {
            if (record.record_type == .append_entry) {
                self.allocator.free(record.data.append_entry.data);
            }
        }

        self.entries.deinit();
        self.wal_buffer.deinit();
        self.log_file.close();
        self.state_file.close();
        self.wal_file.close();
    }

    fn recoverFromWAL(self: *PersistentLog) !void {
        const wal_size = try self.wal_file.getEndPos();
        if (wal_size == 0) {
            return; // Empty WAL
        }

        try self.wal_file.seekTo(0);


        //TODO
        // var reader = self.wal_file.reader();
        var file_buffer: [4096]u8 = undefined;
        var reader = self.wal_file.reader(&file_buffer);


        // Find last checkpoint position
        var current_pos: u64 = 0;
        var last_checkpoint: u64 = 0;

        while (current_pos < wal_size) {
            const pos_before_record = current_pos;
            const record = WALRecord.deserialize(self.allocator, reader) catch break;

            if (record.record_type == .checkpoint) {
                last_checkpoint = pos_before_record;
            }

            // Free memory for append_entry records during scanning
            if (record.record_type == .append_entry) {
                self.allocator.free(record.data.append_entry.data);
            }

            current_pos = try self.wal_file.getPos();
        }

        // Replay from last checkpoint
        try self.wal_file.seekTo(last_checkpoint);
        reader = self.wal_file.reader();

        while (true) {
            const record = WALRecord.deserialize(self.allocator, reader) catch break;

            switch (record.record_type) {
                .append_entry => {
                    try self.entries.append(record.data.append_entry);
                },
                .truncate_from => {
                    const index = record.data.truncate_from;
                    if (index < self.entries.items.len) {
                        // Free memory for truncated entries
                        for (self.entries.items[index..]) |entry| {
                            self.allocator.free(entry.data);
                        }
                        self.entries.shrinkRetainingCapacity(index);
                    }
                },
                .update_term => {
                    self.persistent_state.current_term = record.data.update_term;
                    self.persistent_state.voted_for = null;
                },
                .set_voted_for => {
                    self.persistent_state.voted_for = record.data.set_voted_for;
                },
                .checkpoint => {
                    // Checkpoint marker, continue
                },
            }
        }

        self.last_checkpoint_pos = last_checkpoint;
    }

    fn writeWALRecord(self: *PersistentLog, record: WALRecord) !void {
        try self.wal_buffer.append(record);

        // Flush if buffer is getting full
        if (self.wal_buffer.items.len >= WAL_BUFFER_SIZE) {
            try self.flushWAL();
        }
    }

    fn flushWAL(self: *PersistentLog) !void {
        if (self.wal_buffer.items.len == 0) return;

        const file_size = try self.wal_file.getEndPos();
        try self.wal_file.seekTo(file_size);
        const writer = self.wal_file.writer();

        for (self.wal_buffer.items) |*record| {
            try record.serialize(writer);
        }

        try self.wal_file.sync(); // Force to disk

        // Clear buffer but don't free append_entry data (it's owned by entries array)
        self.wal_buffer.clearRetainingCapacity();
    }

    pub fn checkpoint(self: *PersistentLog) !void {
        // Write checkpoint marker to WAL
        const checkpoint_record = WALRecord{
            .record_type = .checkpoint,
            .data = .{ .checkpoint = {} },
        };
        try self.writeWALRecord(checkpoint_record);
        try self.flushWAL();

        // Persist current state to stable storage
        try self.persistState();
        try self.persistLog();

        // Record checkpoint position
        self.last_checkpoint_pos = try self.wal_file.getPos();

        // Optionally truncate WAL to save space (keep last checkpoint)
        // This is safe because we've persisted everything to stable storage
        try self.truncateWAL();
    }

    fn truncateWAL(self: *PersistentLog) !void {
        // Close and reopen WAL to truncate it
        self.wal_file.close();

        // Reopen with truncate
        const data_dir = "raft_data"; // You might want to store this
        var dir = try std.fs.cwd().openDir(data_dir, .{});
        defer dir.close();

        self.wal_file = try dir.createFile(WAL_FILE_NAME, .{ .read = true, .truncate = true });
        self.last_checkpoint_pos = 0;
    }

    fn loadState(self: *PersistentLog) !void {
        const file_size = try self.state_file.getEndPos();
        if (file_size == 0) {
            // New state file, use defaults
            try self.persistState();
            return;
        }

        try self.state_file.seekTo(0);
        var reader = self.state_file.reader();

        // Verify magic header
        const magic = try reader.readInt(u32, .little);
        if (magic != MAGIC_HEADER) {
            return error.CorruptedStateFile;
        }

        self.persistent_state = try PersistentState.deserialize(reader);
    }

    fn loadLog(self: *PersistentLog) !void {
        const file_size = try self.log_file.getEndPos();
        if (file_size == 0) {
            return; // Empty log file
        }

        try self.log_file.seekTo(0);
        var reader = self.log_file.reader();

        // Verify magic header
        const magic = try reader.readInt(u32, .little);
        if (magic != MAGIC_HEADER) {
            return error.CorruptedLogFile;
        }

        // Read stored CRC32
        const stored_crc = try reader.readInt(u32, .little);

        // Read all data
        const data_start = try self.log_file.getPos();
        const data_size = file_size - data_start;
        const data = try self.allocator.alloc(u8, data_size);
        defer self.allocator.free(data);
        try reader.readNoEof(data);

        // Verify CRC32
        const calculated_crc = crc32.hash(data);
        if (stored_crc != calculated_crc) {
            return error.CorruptedLogFile;
        }

        // Parse data
        var data_stream = std.io.fixedBufferStream(data);
        var data_reader = data_stream.reader();

        // Read number of entries
        const num_entries = try data_reader.readInt(u64, .little);

        // Load each entry
        var i: u64 = 0;
        while (i < num_entries) : (i += 1) {
            const entry = LogEntry.deserialize(self.allocator, data_reader) catch |err| switch (err) {
                error.EndOfStream => break, // Partial write
                else => return err,
            };
            try self.entries.append(entry);
        }
    }

    pub fn persistState(self: *PersistentLog) !void {
        // Serialize data to buffer first
        var data_buffer = std.ArrayList(u8).init(self.allocator);
        defer data_buffer.deinit();

        const data_writer = data_buffer.writer();
        try self.persistent_state.serialize(data_writer);

        // Calculate CRC32
        const data_crc = crc32.hash(data_buffer.items);

        // Write to file
        try self.state_file.seekTo(0);
        var writer = self.state_file.writer();

        try writer.writeInt(u32, MAGIC_HEADER, .little);
        try writer.writeInt(u32, data_crc, .little);
        try writer.writeAll(data_buffer.items);
        try self.state_file.sync();
    }

    pub fn persistLog(self: *PersistentLog) !void {
        // Serialize data to buffer first
        var data_buffer = std.ArrayList(u8).init(self.allocator);
        defer data_buffer.deinit();

        var data_writer = data_buffer.writer();
        try data_writer.writeIntLittleEndian(u64, self.entries.items.len);

        for (self.entries.items) |*entry| {
            try entry.serialize(data_writer);
        }

        // Calculate CRC32
        const data_crc = crc32.hash(data_buffer.items);

        // Write to file
        try self.log_file.seekTo(0);
        var writer = self.log_file.writer();

        try writer.writeIntLittleEndian(u32, MAGIC_HEADER);
        try writer.writeIntLittleEndian(u32, data_crc);
        try writer.writeAll(data_buffer.items);
        try self.log_file.sync();
    }

    // Raft Log interface methods with WAL
    pub fn append(self: *PersistentLog, entry: LogEntry) !void {
        // Clone the data to ensure ownership
        const owned_data = try self.allocator.dupe(u8, entry.data);
        const owned_entry = LogEntry{
            .term = entry.term,
            .index = entry.index,
            .data = owned_data,
        };

        // Write to WAL first
        const wal_record = WALRecord{
            .record_type = .append_entry,
            .data = .{ .append_entry = owned_entry },
        };
        try self.writeWALRecord(wal_record);

        // Then update in-memory state
        try self.entries.append(owned_entry);
    }

    pub fn appendSlice(self: *PersistentLog, entries: []const LogEntry) !void {
        for (entries) |entry| {
            try self.append(entry);
        }
        // Flush WAL after batch
        try self.flushWAL();
    }

    pub fn truncateFrom(self: *PersistentLog, index: u64) !void {
        if (index > self.entries.items.len) return;

        // Write to WAL first
        const wal_record = WALRecord{
            .record_type = .truncate_from,
            .data = .{ .truncate_from = index },
        };
        try self.writeWALRecord(wal_record);

        // Free memory for truncated entries
        var i = index;
        while (i < self.entries.items.len) : (i += 1) {
            self.allocator.free(self.entries.items[i].data);
        }

        // Resize the array
        self.entries.shrinkRetainingCapacity(index);
    }

    pub fn updateTerm(self: *PersistentLog, term: u64) !void {
        if (term > self.persistent_state.current_term) {
            // Write to WAL first
            const wal_record = WALRecord{
                .record_type = .update_term,
                .data = .{ .update_term = term },
            };
            try self.writeWALRecord(wal_record);

            self.persistent_state.current_term = term;
            self.persistent_state.voted_for = null;
        }
    }

    pub fn setVotedFor(self: *PersistentLog, node_id: ?u32) !void {
        // Write to WAL first
        const wal_record = WALRecord{
            .record_type = .set_voted_for,
            .data = .{ .set_voted_for = node_id },
        };
        try self.writeWALRecord(wal_record);

        self.persistent_state.voted_for = node_id;
    }

    pub fn getEntry(self: *PersistentLog, index: u64) ?*const LogEntry {
        if (index == 0 or index > self.entries.items.len) {
            return null;
        }
        return &self.entries.items[index - 1];
    }

    pub fn getLastIndex(self: *PersistentLog) u64 {
        return self.entries.items.len;
    }

    pub fn getLastTerm(self: *PersistentLog) u64 {
        if (self.entries.items.len == 0) return 0;
        return self.entries.items[self.entries.items.len - 1].term;
    }

    pub fn getCurrentTerm(self: *PersistentLog) u64 {
        return self.persistent_state.current_term;
    }

    pub fn getVotedFor(self: *PersistentLog) ?u32 {
        return self.persistent_state.voted_for;
    }
};

pub const MemoryLog = struct {
    allocator: Allocator,
    entries: ArrayList(LogEntry),
    persistent_state: PersistentState,

    pub fn init(allocator: Allocator) !MemoryLog {
        return MemoryLog{
            .allocator = allocator,
            // .entries = ArrayList(LogEntry).init(allocator),
            .entries = .empty,

            .persistent_state = PersistentState{ .current_term = 0, .voted_for = null },
        };
    }

    pub fn deinit(self: *MemoryLog) void {
        // Free allocated entry data
        for (self.entries.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.entries.deinit();
    }

    pub fn append(self: *MemoryLog, entry: LogEntry) !void {
        // Clone the data to ensure ownership
        const owned_data = try self.allocator.dupe(u8, entry.data);
        const owned_entry = LogEntry{
            .term = entry.term,
            .index = entry.index,
            .data = owned_data,
        };

        try self.entries.append(owned_entry);
    }

    pub fn appendSlice(self: *MemoryLog, entries: []const LogEntry) !void {
        for (entries) |entry| {
            try self.append(entry);
        }
    }

    pub fn getEntry(self: *MemoryLog, index: u64) ?*const LogEntry {
        if (index == 0 or index > self.entries.items.len) {
            return null;
        }
        return &self.entries.items[index - 1];
    }

    pub fn getLastIndex(self: *MemoryLog) u64 {
        return self.entries.items.len;
    }

    pub fn getLastTerm(self: *MemoryLog) u64 {
        if (self.entries.items.len == 0) return 0;
        return self.entries.items[self.entries.items.len - 1].term;
    }

    pub fn truncateFrom(self: *MemoryLog, index: u64) !void {
        if (index > self.entries.items.len) return;

        // Free memory for truncated entries
        var i = index;
        while (i < self.entries.items.len) : (i += 1) {
            self.allocator.free(self.entries.items[i].data);
        }

        self.entries.shrinkRetainingCapacity(index);
    }

    pub fn updateTerm(self: *MemoryLog, term: u64) !void {
        if (term > self.persistent_state.current_term) {
            self.persistent_state.current_term = term;
            self.persistent_state.voted_for = null;
        }
    }

    pub fn setVotedFor(self: *MemoryLog, node_id: ?u32) !void {
        self.persistent_state.voted_for = node_id;
    }

    pub fn getCurrentTerm(self: *MemoryLog) u64 {
        return self.persistent_state.current_term;
    }

    pub fn getVotedFor(self: *MemoryLog) ?u32 {
        return self.persistent_state.voted_for;
    }

    // No-op methods for compatibility
    pub fn checkpoint(self: *MemoryLog) !void {
        // No-op for memory log
        _ = self;
    }

    pub fn forceSync(self: *MemoryLog) !void {
        // No-op for memory log
        _ = self;
    }
};

// Modified Log interface to support both memory and persistent storage
pub const Log = union(enum) {
    memory: MemoryLog,
    persistent: PersistentLog,

    pub fn init(allocator: Allocator, opts: std.StringHashMap([]const u8)) !Log {
        const storage_type_str = opts.get("storage_type") orelse "in_memory";

        if (std.mem.eql(u8, storage_type_str, "in_memory")) {
            const memory_log = try MemoryLog.init(allocator);
            return Log{ .memory = memory_log };
        } else if (std.mem.eql(u8, storage_type_str, "persistent")) {
            const data_dir = opts.get("data_dir") orelse return error.DataDirRequired;
            const persistent_log = try PersistentLog.init(allocator, data_dir);
            return Log{ .persistent = persistent_log };
        } else {
            return error.InvalidStorageType;
        }
    }

    pub fn deinit(self: *Log) void {
        switch (self.*) {
            .memory => |*memory_log| memory_log.deinit(),
            .persistent => |*persistent_log| persistent_log.deinit(),
        }
    }

    // Delegate all operations to the appropriate implementation
    pub fn append(self: *Log, entry: LogEntry) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.append(entry),
            .persistent => |*persistent_log| return persistent_log.append(entry),
        }
    }

    pub fn appendSlice(self: *Log, entries: []const LogEntry) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.appendSlice(entries),
            .persistent => |*persistent_log| return persistent_log.appendSlice(entries),
        }
    }

    pub fn getEntry(self: *Log, index: u64) ?*const LogEntry {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.getEntry(index),
            .persistent => |*persistent_log| return persistent_log.getEntry(index),
        }
    }

    pub fn getLastIndex(self: *Log) u64 {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.getLastIndex(),
            .persistent => |*persistent_log| return persistent_log.getLastIndex(),
        }
    }

    pub fn getLastTerm(self: *Log) u64 {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.getLastTerm(),
            .persistent => |*persistent_log| return persistent_log.getLastTerm(),
        }
    }

    pub fn truncateFrom(self: *Log, index: u64) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.truncateFrom(index),
            .persistent => |*persistent_log| return persistent_log.truncateFrom(index),
        }
    }

    pub fn getCurrentTerm(self: *Log) u64 {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.getCurrentTerm(),
            .persistent => |*persistent_log| return persistent_log.getCurrentTerm(),
        }
    }

    pub fn getVotedFor(self: *Log) ?u32 {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.getVotedFor(),
            .persistent => |*persistent_log| return persistent_log.getVotedFor(),
        }
    }

    pub fn updateTerm(self: *Log, term: u64) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.updateTerm(term),
            .persistent => |*persistent_log| return persistent_log.updateTerm(term),
        }
    }

    pub fn setVotedFor(self: *Log, node_id: ?u32) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.setVotedFor(node_id),
            .persistent => |*persistent_log| return persistent_log.setVotedFor(node_id),
        }
    }

    // Additional methods (no-op for memory)
    pub fn checkpoint(self: *Log) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.checkpoint(),
            .persistent => |*persistent_log| return persistent_log.checkpoint(),
        }
    }

    pub fn forceSync(self: *Log) !void {
        switch (self.*) {
            .memory => |*memory_log| return memory_log.forceSync(),
            .persistent => |*persistent_log| return persistent_log.forceSync(),
        }
    }

    pub fn getTermAtIndex(self: *Log, index: u64) ?u64 {
        if (self.getEntry(index)) |x| {
            return x.term;
        }
        return null; // Index doesn't exist
    }

    pub fn sliceFrom(self: *Log, allocator: Allocator, start_index: u64) ![]LogEntry {
        const last_index = self.getLastIndex();
        if (start_index > last_index) {
            return &[_]LogEntry{}; // Empty slice
        }

        var entries = std.ArrayList(LogEntry).init(allocator);
        var i = start_index;
        while (i <= last_index) : (i += 1) {
            if (self.getEntry(i)) |entry| {
                try entries.append(entry.*);
            }
        }
        return entries.toOwnedSlice();
    }
};
