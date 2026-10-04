const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // shared modules
    const entities_mod = b.createModule(.{
        .root_source_file = b.path("src/entities.zig"),
        .target = target,
        .optimize = optimize,
    });

    // normalize module (test-only, not exposed via public API)
    const normalize_mod = b.createModule(.{
        .root_source_file = b.path("src/render/normalize.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "entities", .module = entities_mod }},
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("entities", entities_mod);

    const lib = b.addLibrary(.{ .name = "markdown", .root_module = lib_mod });
    b.installArtifact(lib);

    // unit tests (test blocks inside src/)
    const lib_tests = b.addTest(.{ .root_module = lib_mod });

    // shared conformance harness: fixtures, known-fail lists, runner
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("test/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "markdown", .module = lib_mod },
            .{ .name = "normalize", .module = normalize_mod },
        },
    });

    // conformance / integration tests
    const spec_mod = b.createModule(.{
        .root_source_file = b.path("test/spec_commonmark_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "harness", .module = harness_mod }},
    });
    const spec_tests = b.addTest(.{ .root_module = spec_mod });

    // GFM conformance tests
    const spec_gfm_mod = b.createModule(.{
        .root_source_file = b.path("test/spec_gfm_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "harness", .module = harness_mod }},
    });
    const spec_gfm_tests = b.addTest(.{ .root_module = spec_gfm_mod });

    // Footnote conformance tests (SPEC §13.6)
    const spec_footnote_mod = b.createModule(.{
        .root_source_file = b.path("test/spec_footnote_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "harness", .module = harness_mod }},
    });
    const spec_footnote_tests = b.addTest(.{ .root_module = spec_footnote_mod });

    // MDX conformance tests
    const spec_mdx_mod = b.createModule(.{
        .root_source_file = b.path("test/spec_mdx_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "harness", .module = harness_mod }},
    });
    const spec_mdx_tests = b.addTest(.{ .root_module = spec_mdx_mod });

    // HTML normalizer tests
    const normalize_test_mod = b.createModule(.{
        .root_source_file = b.path("test/normalize_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    normalize_test_mod.addImport("normalize", normalize_mod);
    const normalize_tests = b.addTest(.{ .root_module = normalize_test_mod });

    // robustness tests (allocator failure injection)
    const robustness_mod = b.createModule(.{
        .root_source_file = b.path("test/alloc_failure_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    robustness_mod.addImport("markdown", lib_mod);
    const robustness_tests = b.addTest(.{ .root_module = robustness_mod });

    // AST snapshot tests (SPEC §16.2)
    const ast_mod = b.createModule(.{
        .root_source_file = b.path("test/ast_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_mod.addImport("markdown", lib_mod);
    const ast_tests = b.addTest(.{ .root_module = ast_mod });

    // MDX policy tests (SPEC §12.2)
    const mdx_policy_mod = b.createModule(.{
        .root_source_file = b.path("test/mdx_policy_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mdx_policy_mod.addImport("markdown", lib_mod);
    const mdx_policy_tests = b.addTest(.{ .root_module = mdx_policy_mod });

    // debug-conformance tool (SPEC §16.1.1)
    const debug_conf_mod = b.createModule(.{
        .root_source_file = b.path("test/tools/debug_conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "harness", .module = harness_mod },
            .{ .name = "markdown", .module = lib_mod },
            .{ .name = "normalize", .module = normalize_mod },
        },
    });
    const debug_conf = b.addExecutable(.{ .name = "debug-conformance", .root_module = debug_conf_mod });
    b.installArtifact(debug_conf);

    // scalability gate (SPEC §16.4). Always ReleaseFast: growth ratios taken
    // from a debug build measure the debug build, not the algorithm.
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("test/tools/perf.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{.{ .name = "markdown", .module = lib_mod }},
    });
    const perf_exe = b.addExecutable(.{ .name = "perf", .root_module = perf_mod });
    b.installArtifact(perf_exe);

    // fuzz / oracle differential (SPEC §16.5)
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/tools/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "markdown", .module = lib_mod }},
    });
    const fuzz_exe = b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_mod });
    b.installArtifact(fuzz_exe);

    // step: test-unit (src/ test blocks only)
    const test_unit_step = b.step("test-unit", "Run unit tests only");
    test_unit_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // step: test-conformance (fixture-based conformance)
    const test_conf_step = b.step("test-conformance", "Run conformance tests only");
    test_conf_step.dependOn(&b.addRunArtifact(spec_tests).step);
    test_conf_step.dependOn(&b.addRunArtifact(spec_gfm_tests).step);
    test_conf_step.dependOn(&b.addRunArtifact(spec_footnote_tests).step);
    test_conf_step.dependOn(&b.addRunArtifact(spec_mdx_tests).step);
    test_conf_step.dependOn(&b.addRunArtifact(normalize_tests).step);

    // step: test-footnote (footnote fixtures only, SPEC §13.6)
    const test_footnote_step = b.step("test-footnote", "Run footnote conformance only");
    test_footnote_step.dependOn(&b.addRunArtifact(spec_footnote_tests).step);

    // step: test-robustness (allocator failure injection)
    const test_robustness_step = b.step("test-robustness", "Run robustness tests only");
    test_robustness_step.dependOn(&b.addRunArtifact(robustness_tests).step);

    // step: test-perf (scalability gate, SPEC §16.4)
    const test_perf_step = b.step("test-perf", "Check that parsing stays linear in input length");
    test_perf_step.dependOn(&b.addRunArtifact(perf_exe).step);

    // step: test-fuzz (property-based fuzz, SPEC §16.5)
    const test_fuzz_step = b.step("test-fuzz", "Run property-based fuzz testing");
    test_fuzz_step.dependOn(&b.addRunArtifact(fuzz_exe).step);

    // step: test (everything)
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_gfm_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_mdx_tests).step);
    test_step.dependOn(&b.addRunArtifact(normalize_tests).step);
    test_step.dependOn(&b.addRunArtifact(robustness_tests).step);
    test_step.dependOn(&b.addRunArtifact(ast_tests).step);
    test_step.dependOn(&b.addRunArtifact(mdx_policy_tests).step);
    test_step.dependOn(&b.addRunArtifact(spec_footnote_tests).step);
    test_step.dependOn(&b.addRunArtifact(perf_exe).step);
    test_step.dependOn(&b.addRunArtifact(fuzz_exe).step);

    // step: debug-conformance (run the debug tool)
    const debug_conf_step = b.step("debug-conformance", "Run conformance and dump failing examples");
    debug_conf_step.dependOn(&b.addRunArtifact(debug_conf).step);
}
