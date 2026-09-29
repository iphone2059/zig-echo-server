const std = @import("std");

fn addMsvcSdkEnvironment(b: *std.Build, module: *std.Build.Module) void {
    const include_env = b.graph.environ_map.get("INCLUDE") orelse
        @panic("INCLUDE is not set. Run from x64 Native Tools/Developer PowerShell for VS 2022, or call VsDevCmd.bat first.");
    var includes = std.mem.tokenizeScalar(u8, include_env, ';');
    while (includes.next()) |path| {
        if (path.len != 0) module.addIncludePath(.{ .cwd_relative = path });
    }

    const lib_env = b.graph.environ_map.get("LIB") orelse
        @panic("LIB is not set. Run from x64 Native Tools/Developer PowerShell for VS 2022, or call VsDevCmd.bat first.");
    var libs = std.mem.tokenizeScalar(u8, lib_env, ';');
    while (libs.next()) |path| {
        if (path.len != 0) module.addLibraryPath(.{ .cwd_relative = path });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (target.result.os.tag != .windows or target.result.abi != .msvc) {
        @panic("zig-echo-server requires target x86_64-windows-msvc (or another Windows MSVC ABI target)");
    }

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addMsvcSdkEnvironment(b, root_module);
    root_module.linkSystemLibrary("ws2_32", .{ .use_pkg_config = .no });
    root_module.linkSystemLibrary("kernel32", .{ .use_pkg_config = .no });

    const exe = b.addExecutable(.{
        .name = "zig-echo-server",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addMsvcSdkEnvironment(b, test_module);
    test_module.linkSystemLibrary("ws2_32", .{ .use_pkg_config = .no });
    test_module.linkSystemLibrary("kernel32", .{ .use_pkg_config = .no });

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run contract and heap tests");
    test_step.dependOn(&run_tests.step);

    const acceptance_step = b.step("acceptance", "Run the currently available acceptance suite");
    acceptance_step.dependOn(&run_tests.step);

    const contract_module = b.createModule(.{
        .root_source_file = b.path("tests/contracts.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    contract_module.addImport("server", test_module);
    const contract_tests = b.addTest(.{ .root_module = contract_module });
    const run_contract_tests = b.addRunArtifact(contract_tests);
    const contract_step = b.step("test-contracts", "Run exact server CLI and pure contract tests");
    contract_step.dependOn(&run_contract_tests.step);
}
