const Command = @import("command.zig").Command;
// const CommandWithId = @import("command.zig").Command;

pub const LogEntry = struct {
    term: u64,
    command: Command,
    // command: CommandWithId,
    command_id: ?u64 = null,
};
