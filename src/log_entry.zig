const Command = @import("command.zig").Command;

pub const LogEntry = struct {
    term: u64,
    command: Command,
};
