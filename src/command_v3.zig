const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Command = union(enum) {
    set: struct {
        key: []const u8,
        value: []const u8,
    },

    delete: struct {
        key: []const u8,
    },

    update: struct {
        key: []const u8,
        value: []const u8,
    },

    get: struct {
        key: []const u8,
    },

    compare_and_swap: struct {
        key: []const u8,
        expected: []const u8,
        new_value: []const u8,
    },

    batch: struct {
        operations: []Command,
    },

    raw: struct {
        data: []const u8,
    },

    const Self = @This();

    // Serialize command to bytes
    pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
        var buffer = ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        // Write command type
        try writer.writeByte(@intFromEnum(self.*));

        switch (self.*) {
            .set => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.key.len), .little);
                try writer.writeAll(cmd.key);
                try writer.writeInt(u32, @intCast(cmd.value.len), .little);
                try writer.writeAll(cmd.value);
            },
            .delete => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.key.len), .little);
                try writer.writeAll(cmd.key);
            },

            .get => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.key.len), .little);
                try writer.writeAll(cmd.key);
            },

            .update => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.key.len), .little);
                try writer.writeAll(cmd.key);
                try writer.writeInt(u32, @intCast(cmd.value.len), .little);
                try writer.writeAll(cmd.value);
            },
            .compare_and_swap => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.key.len), .little);
                try writer.writeAll(cmd.key);
                try writer.writeInt(u32, @intCast(cmd.expected.len), .little);
                try writer.writeAll(cmd.expected);
                try writer.writeInt(u32, @intCast(cmd.new_value.len), .little);
                try writer.writeAll(cmd.new_value);
            },
            .batch => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.operations.len), .little);
                for (cmd.operations) |*op| {
                    const op_data = try op.serialize(allocator);
                    defer allocator.free(op_data);
                    try writer.writeInt(u32, @intCast(op_data.len), .little);
                    try writer.writeAll(op_data);
                }
            },
            .raw => |cmd| {
                try writer.writeInt(u32, @intCast(cmd.data.len), .little);
                try writer.writeAll(cmd.data);
            },
        }

        return buffer.toOwnedSlice();
    }

    // Deserialize command from bytes
    pub fn deserialize(allocator: Allocator, data: []const u8) !Self {
        if (data.len == 0) return error.InvalidCommandData;

        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        const cmd_type = try reader.readByte();

        return switch (cmd_type) {
            @intFromEnum(Command.set) => {
                const key_len = try reader.readInt(u32, .little);
                const key = try allocator.alloc(u8, key_len);
                try reader.readNoEof(key);

                const value_len = try reader.readInt(u32, .little);
                const value = try allocator.alloc(u8, value_len);
                try reader.readNoEof(value);

                return Command{ .set = .{ .key = key, .value = value } };
            },
            @intFromEnum(Command.delete) => {
                const key_len = try reader.readInt(u32, .little);
                const key = try allocator.alloc(u8, key_len);
                try reader.readNoEof(key);

                return Command{ .delete = .{ .key = key } };
            },
            @intFromEnum(Command.update) => {
                const key_len = try reader.readInt(u32, .little);
                const key = try allocator.alloc(u8, key_len);
                try reader.readNoEof(key);

                const value_len = try reader.readInt(u32, .little);
                const value = try allocator.alloc(u8, value_len);
                try reader.readNoEof(value);

                return Command{ .update = .{ .key = key, .value = value } };
            },
            @intFromEnum(Command.get) => {
                const key_len = try reader.readInt(u32, .little);
                const key = try allocator.alloc(u8, key_len);
                try reader.readNoEof(key);

                return Command{ .get = .{ .key = key } };
            },
            @intFromEnum(Command.compare_and_swap) => {
                const key_len = try reader.readInt(u32, .little);
                const key = try allocator.alloc(u8, key_len);
                try reader.readNoEof(key);

                const expected_len = try reader.readInt(u32, .little);
                const expected = try allocator.alloc(u8, expected_len);
                try reader.readNoEof(expected);

                const new_value_len = try reader.readInt(u32, .little);
                const new_value = try allocator.alloc(u8, new_value_len);
                try reader.readNoEof(new_value);

                return Command{ .compare_and_swap = .{ .key = key, .expected = expected, .new_value = new_value } };
            },
            @intFromEnum(Command.batch) => {
                const op_count = try reader.readInt(u32, .little);
                const operations = try allocator.alloc(Command, op_count);

                for (operations) |*op| {
                    const op_len = try reader.readInt(u32, .little);
                    const op_data = try allocator.alloc(u8, op_len);
                    defer allocator.free(op_data);
                    try reader.readNoEof(op_data);

                    op.* = try Command.deserialize(allocator, op_data);
                }

                return Command{ .batch = .{ .operations = operations } };
            },
            @intFromEnum(Command.raw) => {
                const data_len = try reader.readInt(u32, .little);
                const raw_data = try allocator.alloc(u8, data_len);
                try reader.readNoEof(raw_data);

                return Command{ .raw = .{ .data = raw_data } };
            },
            else => return error.UnknownCommandType,
        };
    }

    // Free allocated memory for command
    pub fn deinit(self: *const Self, allocator: Allocator) void {
        switch (self.*) {
            .set => |cmd| {
                allocator.free(cmd.key);
                allocator.free(cmd.value);
            },
            .delete, .get => |cmd| {
                allocator.free(cmd.key);
            },
            .update => |cmd| {
                allocator.free(cmd.key);
                allocator.free(cmd.value);
            },
            .compare_and_swap => |cmd| {
                allocator.free(cmd.key);
                allocator.free(cmd.expected);
                allocator.free(cmd.new_value);
            },
            .batch => |cmd| {
                for (cmd.operations) |*op| {
                    op.deinit(allocator);
                }
                allocator.free(cmd.operations);
            },
            .raw => |cmd| {
                allocator.free(cmd.data);
            },
        }
    }

    // Convert to raw data for backward compatibility
    pub fn toRawData(self: *const Self, allocator: Allocator) ![]u8 {
        return self.serialize(allocator);
    }

    // Create command from raw data for backward compatibility
    pub fn fromRawData(allocator: Allocator, data: []const u8) !Self {
        // Try to deserialize as command first
        return Command.deserialize(allocator, data) catch {
            // If deserialization fails, treat as raw data
            const owned_data = try allocator.dupe(u8, data);
            return Command{ .raw = .{ .data = owned_data } };
        };
    }
};

pub const ClientCommandResult = union(enum) {
    write_result: struct {
        index: u64,
        term: u64,
    },
    query_result: struct {
        value: ?[]const u8,
    },
    err: enum {
        not_leader,
        state_machine_not_initialized,
        leadership_lost,
        leadership_uncertain,
        internal_error,
        timeout,
    },
};
