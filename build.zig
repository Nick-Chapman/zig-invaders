const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "invaders",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        }),
    });

    exe.root_module.addAnonymousImport("wallclock", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/wallclock.zig"),
    });

    exe.linkSystemLibrary("SDL2");
    exe.linkLibC();
    b.installArtifact(exe);

    const run = b.step("run", "Run Space Invaders");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
}
