const std = @import("std");
const server = @import("server");
const c = server.win32.c;

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 6) return 1;
    const port = std.fmt.parseInt(u16, argv[1], 10) catch return 1;
    const run_seconds = std.fmt.parseInt(u32, argv[2], 10) catch return 1;
    const cq_capacity = std.fmt.parseInt(u32, argv[3], 10) catch return 1;
    const memory_bytes = std.fmt.parseInt(u64, argv[4], 10) catch return 1;
    const timeout_seconds = std.fmt.parseInt(u32, argv[5], 10) catch return 1;
    var options: server.types.Options = .{
        .protocol = .tcp,
        .port = port,
        .timeout_seconds = timeout_seconds,
        .run_seconds = run_seconds,
        .worker_count = 1,
        .rio_buffer_bytes = 4096,
        .cq_capacity = cq_capacity,
        .memory_bytes = memory_bytes,
        .quiet = true,
    };

    var winsock = server.win32.Winsock.init() catch return 2;
    defer winsock.deinit();
    var api = server.rio.Api.load() catch return 2;
    var failed = std.atomic.Value(bool).init(false);
    var worker: server.engine_internal.Worker = .{};
    var worker_resources: server.tcp_worker.WorkerResources = .{};
    server.tcp_worker.initializeWorker(&worker, &api, &options, &failed, 0, 1, &worker_resources) catch return 2;
    if (!server.tcp_worker.startWorker(&worker)) {
        server.tcp_worker.postAdmissionClosed(&worker);
        server.tcp_worker.postStop(&worker);
        server.tcp_worker.destroyWorker(&worker);
        return 2;
    }

    var acceptor: server.engine_internal.Acceptor = .{};
    var acceptor_resources: server.tcp_acceptor.AcceptorResources = .{};
    server.tcp_acceptor.initializeAcceptor(&acceptor, &api, &options, @as([*]server.engine_internal.Worker, @ptrCast(&worker))[0..1], &failed, &acceptor_resources) catch {
        server.tcp_worker.postAdmissionClosed(&worker);
        server.tcp_worker.postStop(&worker);
        server.tcp_worker.destroyWorker(&worker);
        return 2;
    };
    if (!server.tcp_acceptor.startAcceptor(&acceptor)) {
        if (acceptor.thread != null) server.tcp_acceptor.stopAcceptor(&acceptor) else server.tcp_worker.postAdmissionClosed(&worker);
        server.tcp_acceptor.destroyAcceptor(&acceptor);
        server.tcp_worker.postStop(&worker);
        server.tcp_worker.destroyWorker(&worker);
        return 2;
    }

    c.Sleep(run_seconds * 1000);
    server.tcp_acceptor.stopAcceptor(&acceptor);
    server.tcp_acceptor.joinAcceptor(&acceptor);
    server.tcp_worker.postStop(&worker);
    server.tcp_worker.joinWorker(&worker);
    const active = worker.active_count;
    server.tcp_acceptor.destroyAcceptor(&acceptor);
    server.tcp_worker.destroyWorker(&worker);

    var output_buffer: [128]u8 = undefined;
    const output = std.fmt.bufPrint(&output_buffer, "tcp_driver active={d} failed={s}\n", .{ active, if (failed.load(.acquire)) "true" else "false" }) catch return 4;
    if (!server.win32.writeStdout(output)) return 4;
    return if (failed.load(.acquire)) 2 else 0;
}
