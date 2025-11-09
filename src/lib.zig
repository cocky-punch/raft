pub const RaftNode = @import("core.zig").RaftNode;
pub const Cluster = @import("core.zig").Cluster;
pub const Command = @import("command.zig").Command;
pub const RpcMessage = @import("types.zig").RpcMessage;
pub const Config = @import("config.zig").Config;
pub const StateMachine = @import("state_machine.zig").StateMachine;
pub const LogEntry = @import("log.zig").LogEntry;
pub const RaftTcpServer = @import("raft_tcp_server.zig").RaftTcpServer;
pub const sendFramedRpc = @import("raft_tcp_server.zig").sendFramedRpc;

//import the modules in order trigger the tests
comptime {
    if (@import("builtin").is_test) {
        _ = @import("core.zig");
        _ = @import("config.zig");
        _ = @import("raft_test.zig");
    }
}
