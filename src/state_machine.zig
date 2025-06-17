const std = @import("std");

const LogEntry = @import("log_entry.zig").LogEntry;

pub fn StateMachine(comptime T: type) type {
    return struct {
        ctx: *T,
        apply: *const fn (*T, LogEntry) void,

        pub fn init(ctx: *T, apply_fn: fn (*T, LogEntry) void) StateMachine(T) {
            return .{
                .ctx = ctx,
                .apply = apply_fn,
            };
        }

        pub fn applyLog(self: StateMachine(T), entry: LogEntry) void {
            self.apply(self.ctx, entry);
        }

        pub fn serialize(self: StateMachine(T), writer: anytype) !void {
            if (@hasDecl(T, "serialize")) {
                return self.ctx.serialize(writer);
            } else {
                // @compileError("T must implement `fn serialize(self: *T, writer: anytype) !void` to use snapshotting.");
                std.debug.print("[warn] serialize() called but not implemented for T\n", .{});
                return error.MethodNotImplemented;
            }
        }

        pub fn deserialize(self: StateMachine(T), data: []const u8) !void {
            if (@hasDecl(T, "deserialize")) {
                return self.ctx.deserialize(data);
            } else {
                // @compileError("T must implement `fn deserialize(self: *T, data: []const u8) !void` to restore snapshot.");
                //
                std.debug.print("[warn] deserialize() called but not implemented for T\n", .{});
                return error.MethodNotImplemented;
            }
        }
    };
}
