const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Version string") orelse "0.0.0");

    // No libc and nothing else linked: the result is a static binary that
    // runs on any x86_64 Linux, which is the whole of the install story.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // A daemon's panic trace goes to the journal, where addresses are
        // enough; the debug info would be nine tenths of the binary.
        .strip = optimize != .Debug,
    });
    root.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "glim", .root_module = root });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
