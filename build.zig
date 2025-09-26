const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //dependencies
    //yaml
    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });


    // Library module (main export)
    const raft_lib = b.addModule("raft", .{
        //FIXME
        // .root_source_file = b.path("src/lib.zig"),
        // .root_module = b.addModule("raft", .{ .root_source_file = .{.path = "src/lib.zig"}}),
        // .root_module = b.createModule("raft", .{
        //     .root_source_file = .{.path = "src/lib.zig"}
        // }),

        .root_source_file = b.path("src/lib.zig"),

        .imports = &.{
            .{ .name = "yaml", .module = yaml_dep.module("yaml") },
        },
    });

    _ = raft_lib;

    // Examples
    // const examples = [_][]const u8{
    //     "ex1",
    //     //"ex2"
    //     //"ex3"
    // };
    // for (examples) |example_name| {
    //     const exe = b.addExecutable(.{
    //         .name = example_name,
    // //         .root_source_file = b.path(b.fmt("examples/{s}/src/main.zig", .{example_name})),
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     exe.root_module.addImport("raft", raft_lib);
    //     b.installArtifact(exe);
    // }

    // Tests
    const tests = b.addTest(.{
        // (1)
        // .root_source_file = b.path("src/lib.zig"),

        // (2)
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),


        // TODO
        // .target = target,
        // .optimize = optimize,
    });
    tests.root_module.addImport("yaml", yaml_dep.module("yaml"));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step); // Need the RUN artifact, not just the test artifact
}
