const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "raft_node",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add relative dependency on main Raft library (from ../..)
    exe.addModule("raft", b.createModule(.{
        .root_source_file = b.path("../../src/raft.zig"),
    }));

    b.installArtifact(exe);

    const cli = b.addExecutable(.{
        .name = "raft_cli",
        .root_source_file = b.path("cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.addModule("raft", b.createModule(.{
        .root_source_file = b.path("../../src/raft.zig"),
    }));

    b.installArtifact(cli);
}
