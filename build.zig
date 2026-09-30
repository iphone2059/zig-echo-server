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

    const acceptance_step = b.step("acceptance", "Run the complete self-contained server acceptance suite");
    acceptance_step.dependOn(test_step);

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

    const engine_test_module = b.createModule(.{
        .root_source_file = b.path("tests/engine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_test_module.addImport("server", test_module);
    const engine_tests = b.addTest(.{ .root_module = engine_test_module });
    const run_engine_tests = b.addRunArtifact(engine_tests);

    const stream_driver_module = b.createModule(.{
        .root_source_file = b.path("tests/stream_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stream_driver_module.addImport("server", test_module);
    const stream_driver = b.addExecutable(.{
        .name = "server-stream-driver",
        .root_module = stream_driver_module,
    });
    const run_stream_driver = b.addRunArtifact(stream_driver);
    run_stream_driver.expectStdOutEqual("stdout-only\n");
    run_stream_driver.expectStdErrEqual("stderr-only\n");

    const engine_step = b.step("test-engine", "Run server ownership and engine tests");
    engine_step.dependOn(&run_engine_tests.step);
    engine_step.dependOn(&run_stream_driver.step);

    const udp_stop_module = b.createModule(.{
        .root_source_file = b.path("tests/udp_stop_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    udp_stop_module.addImport("server", test_module);
    const udp_stop_driver = b.addExecutable(.{
        .name = "zig-echo-server-udp-stop-driver",
        .root_module = udp_stop_module,
    });
    b.installArtifact(udp_stop_driver);

    const tcp_acceptor_driver_module = b.createModule(.{
        .root_source_file = b.path("tests/tcp_acceptor_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tcp_acceptor_driver_module.addImport("server", test_module);
    const tcp_acceptor_driver = b.addExecutable(.{
        .name = "zig-echo-server-tcp-acceptor-driver",
        .root_module = tcp_acceptor_driver_module,
    });
    b.installArtifact(tcp_acceptor_driver);

    const fault_driver_module = b.createModule(.{
        .root_source_file = b.path("tests/fault_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fault_driver_module.addImport("server", test_module);
    const fault_driver = b.addExecutable(.{
        .name = "zig-echo-server-fault-driver",
        .root_module = fault_driver_module,
    });
    b.installArtifact(fault_driver);

    const abi_module = b.createModule(.{
        .root_source_file = b.path("tests/sdk_abi_driver.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_module.addImport("server", test_module);
    const abi_driver = b.addExecutable(.{
        .name = "zig-echo-server-sdk-abi-driver",
        .root_module = abi_module,
    });
    b.installArtifact(abi_driver);

    const source_policy = b.addSystemCommand(&.{ "pwsh.exe", "-NoProfile", "-File", "tests/source_policy.ps1" });
    const fault_process = b.addSystemCommand(&.{ "pwsh.exe", "-NoProfile", "-File", "tests/fault_process_tests.ps1" });
    const process_tests = b.addSystemCommand(&.{ "pwsh.exe", "-NoProfile", "-File", "tests/process_tests.ps1" });
    const abi_contract = b.addSystemCommand(&.{ "pwsh.exe", "-NoProfile", "-File", "tests/sdk_abi_contract.ps1" });
    fault_process.step.dependOn(b.getInstallStep());
    process_tests.step.dependOn(b.getInstallStep());
    abi_contract.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_contract_tests.step);
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_stream_driver.step);
    test_step.dependOn(&source_policy.step);
    test_step.dependOn(&fault_process.step);
    test_step.dependOn(&process_tests.step);
    test_step.dependOn(&abi_contract.step);
}
