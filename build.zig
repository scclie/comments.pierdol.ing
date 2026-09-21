const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const pg_dep = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "comments-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "pg", .module = pg_dep.module("pg") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    const markdown_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/markdown.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const ratelimit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ratelimit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const nickgen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nickgen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const matrix_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/matrix.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_markdown_tests = b.addRunArtifact(markdown_tests);
    const run_ratelimit_tests = b.addRunArtifact(ratelimit_tests);
    const run_nickgen_tests = b.addRunArtifact(nickgen_tests);
    const run_matrix_tests = b.addRunArtifact(matrix_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_markdown_tests.step);
    test_step.dependOn(&run_ratelimit_tests.step);
    test_step.dependOn(&run_nickgen_tests.step);
    test_step.dependOn(&run_matrix_tests.step);
}
