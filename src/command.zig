const std = @import("std");

pub const Command = union(enum) {
    Set: struct {
        key: []const u8,
        value: []const u8,
    },
    Delete: struct {
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
        }
    }
};
