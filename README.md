# Raft [WIP]

An implementation of Raft Consensus Algorithm in Zig


## Installation

Fetch the master or a release

```
zig fetch --save https://github.com/cocky-punch/raft/archive/refs/heads/master.tar.gz
# or by a release version
# zig fetch --save https://github.com/cocky-punch/raft/archive/refs/tags/[RELEASE_VERSION].tar.gz
```
which will save a reference to the library into build.zig.zon

Then add this into build.zig

```
// after "b.installArtifact(exe)" line
const raft = b.dependency("raft", .{
  .target = target,
  .optimize = optimize,
});
exe.root_module.addImport("raft", raft.module("raft"));
```


And in your Zig code

```
const raft = @import("raft");
// ........
```

## Usage
