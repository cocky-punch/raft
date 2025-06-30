const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_module = yaml_dep.module("yaml");

    const raft_module = b.createModule(.{
        // .root_source_file = b.path("../../src/raft.zig"),
        .root_source_file = b.path("../../src/lib.zig"),

        .imports = &.{
            .{ .name = "yaml", .module = yaml_module },
        },
    });


    //TODO
    const config_module = b.createModule(.{
        .root_source_file = b.path("../../src/config.zig"),
    });
    _ = config_module;

    const types_module = b.createModule(.{
        .root_source_file = b.path("../../src/types.zig"),
    });
    _ = types_module;


    //
    //exe
    //
    const exe = b.addExecutable(.{
        .name = "raft_node",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("raft", raft_module);
    // exe.root_module.addImport("config", config_module);
    // exe.root_module.addImport("types", types_module);
    b.installArtifact(exe);
    b.default_step.dependOn(&exe.step);
    const run_node = b.addRunArtifact(exe);
    b.step("run-node", "Run raft_node binary").dependOn(&run_node.step);


    //
    //cli
    //
    const cli = b.addExecutable(.{
        .name = "raft_cli",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    cli.root_module.addImport("raft", raft_module);
    // cli.root_module.addImport("config", config_module);
    // cli.root_module.addImport("types", types_module);
    // b.installArtifact(cli);

    // b.default_step.dependOn(&cli.step);
    // const run_cli = b.addRunArtifact(cli);
    // b.step("run-cli", "Run raft_cli binary").dependOn(&run_cli.step);
}
