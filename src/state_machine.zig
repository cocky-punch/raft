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
    };
}
