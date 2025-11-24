# Raft [WIP]

An implementation of Raft Consensus Algorithm in Zig

## Features
- [ ] support of Zig 0.15
- [x] Leader tracking
- [x] In-memory transport
- [x] Cluster-wide coordination
- [x] Client redirection
- [x] Election timeout logic
- [x] Client command submission
- [x] Log replication
- [x] Apply committed entries
- [x] Heartbeats / ticks
- [x] State machine plumbing
- [ ] In-memory transport
- [ ] Json-RPC HTTP transport
- [ ] gRPC transport
- [ ] Client acknowledgment / client request retries - confirmations
- [ ] Persistent log
- [ ] Rotation of the log files
- [ ] Persistent snapshots
- [ ] Proper handler of `TimeoutNow` -  Leadership Transfer Mechanism - message (Raft extensions)
- [ ] Read-only GET message (Raft extensions)

## Installation

Fetch the master or a release

```bash
zig fetch --save https://github.com/cocky-punch/raft/archive/refs/heads/master.tar.gz
# or by a release version
# zig fetch --save https://github.com/cocky-punch/raft/archive/refs/tags/[RELEASE_VERSION].tar.gz
```
which will save a reference to the library into build.zig.zon

Then add this into build.zig

```zig
// after "b.installArtifact(exe)" line
const raft = b.dependency("raft", .{
  .target = target,
  .optimize = optimize,
});
exe.root_module.addImport("raft", raft.module("raft"));
```


## Usage

* Implement `MyStateMachine#apply(...)`
* create a config for each node
* in each config specify a node itself and all the nodes, including itself again, of a cluster
* run each of the nodes
* interract with them via the cli-client

```zig
const std = @import("std");
const raft = @import("raft");

const Allocator = std.mem.Allocator;

// Your own state machine implementation.
// This will apply committed commands (Set/Delete) to a file
const MyStateMachine = struct {
    db_file: std.fs.File,

    // Interface function
    // Custom implementation, for a custom storage
    pub fn apply(self: *MyStateMachine, entry: raft.LogEntry) void {
        switch (entry.command) {
            .Set => |cmd| {
                // Simulate persistent insert by appending to file
                _ = self.db_file.writer().print("SET {s} {any}\n", .{cmd.key, cmd.value}) catch {};
            },
            .Delete => |cmd| {
                _ = self.db_file.writer().print("DELETE {s}\n", .{cmd.key}) catch {};
            },


            //TODO
            .Update => |u| {
                // Optional: check if key exists first
                if (!self.db.contains(u.key)) return error.KeyNotFound;
                try self.db_file_update_key(u.key, u.value); // Overwrite
            },
            //TODO
            .Get => |cmd| {
                // find a value in the file
            },
        }
    }

    pub fn init() !MyStateMachine {
        const f = try std.fs.cwd().createFile("raft_db.txt", .{ .read = true, .truncate = false });
        return MyStateMachine{ .db_file = f };
    }

    pub fn deinit(self: *MyStateMachine) void {
        self.db_file.close();
    }

    //mock method
    inline fn db_file_contain_key(k: string) bool {
        return true;
    }

    //mock method
    inline fn db_file_update_key(k: string, v: string) void {
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load config
    const config = try raft.loadConfig(allocator, "node1_raft.yaml");

    // Wrap the state machine logic
    var sm_impl = try MyStateMachine.init();
    const sm = raft.StateMachine(MyStateMachine){
        .ctx = &sm_impl,
    };

    const Node = raft.RaftNode(MyStateMachine);
    const ClusterT = raft.InMemorySimulatedCluster(MyStateMachine);
    var cluster = ClusterT.init(allocator);
    var node = try Node.init(allocator, config.self_id, sm);

    for (config.nodes) |peer| {
        try cluster.addNodeAddress(peer.id, peer.address);
    }

    // Start TCP server in background
    var server = raft.RaftTcpServer(MyStateMachine).init(
        allocator,
        &node,
        &cluster,
        50, // max clients
    );
    const self_port = blk: {
        for (config.nodes) |p| {
            if (p.id == config.self_id) break :blk p.address.port;
        }
        return error.SelfNotFound;
    };
    const t = try std.Thread.spawn(.{}, raft.RaftTcpServer(MyStateMachine).start, .{ &server, self_port });
    t.detach();

    // Main loop: Raft ticking (election, heartbeat, etc.)
    while (true) {
        try cluster.processInMemoryData();
        try server.checkCommittedAcks(); // sends acks to clients if commit_index advanced
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}

```


## Examples
in the corresponding directory
