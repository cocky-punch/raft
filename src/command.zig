const std = @import("std");

pub const Command = union(enum) {
    Set: struct {
        key: []const u8,
        value: []const u8,
    },
    Delete: struct {
        key: []const u8,
    },
    Update: struct {
        key: []const u8,
        value: []const u8,
    },
    Get: struct {
        key: []const u8,
    },

    pub fn format(
        self: Command,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .Set => |cmd| try writer.print("Set({s} = {s})", .{ cmd.key, cmd.value }),
            .Delete => |cmd| try writer.print("Delete({s})", .{cmd.key}),
            .Update => |cmd| try writer.print("Update({s} = {s})", .{ cmd.key, cmd.value }),
            .Get => |cmd| try writer.print("Get({s})", .{cmd.key}),
        }
    }
};

pub const CommandWithId = struct {
    id: u64,
    command: Command,
};
