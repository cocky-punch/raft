const std = @import("std");
const LogEntry = @import("log.zig").LogEntry;

pub fn StateMachine(comptime T: type) type {
    return struct {
        ctx: *T,

        pub fn init(ctx: *T) @This() {
            if (!@hasDecl(T, "apply")) {
                @compileError("StateMachine/T must implement: fn apply(self: *T, entry: LogEntry) void");
            }

            if (!@hasDecl(T, "queryGet")) {
                @compileError("StateMachine/T must implement: fn queryGet(self: *T, key: []const u8) []const u8");
            }

            return .{
                .ctx = ctx,
            };
        }

        pub fn applyLog(self: @This(), entry: LogEntry) void {
            T.apply(self.ctx, entry);
        }

        pub fn queryGet(self: @This(), key: []const u8) []const u8 {
            return T.queryGet(self.ctx, key);
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
