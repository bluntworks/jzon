const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jzon_mod = b.addModule("jzon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests for each source file
    const src_files = [_][]const u8{
        "src/escape.zig",
        "src/scanner.zig",
        "src/path.zig",
        "src/writer.zig",
        "src/assembler.zig",
        "src/root.zig",
    };

    const test_step = b.step("test", "Run all tests");

    for (src_files) |src| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Benchmark executable
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("jzon", jzon_mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    // Deterministic simulation tests
    const sim_mod = b.createModule(.{
        .root_source_file = b.path("test/sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_mod.addImport("jzon", jzon_mod);
    const sim_tests = b.addTest(.{ .root_module = sim_mod });
    const run_sim = b.addRunArtifact(sim_tests);
    test_step.dependOn(&run_sim.step);

    // Integration tests
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("jzon", jzon_mod);
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
}
