# Raft [WIP]

An implementation of Raft Consensus Algorithm in Zig


## Installation

Calculate a hash:

```
zig fetch https://github.com/<this user / repo>/archive/refs/heads/master.tar.gz
```

### Add to build.zig.zon

```
.{
    .name = "your_project123",
    .version = "0.1.0",
    .dependencies = .{
        .raft = .{
            .url = "https://github.com/<this user / repo>/archive/refs/heads/master.tar.gz",
            .hash = "<INSERT_HASH_HERE>",
        },
    },
}
```

Import it into your build.zig:

```
const raft_dep = b.dependency("raft", .{});
exe.addModule("raft", raft_dep.module("raft"));
```

Then in your Zig code:

```
const raft = @import("raft");
// TODO....
```

## Usage
