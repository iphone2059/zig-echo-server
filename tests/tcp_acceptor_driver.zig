//! Drives a real acceptor and one worker with a live listener, so the accept window, the admission
//! credits and the shutdown barrier are exercised against the machine rather than a model.

const std = @import("std");
const server = @import("server");
const c = server.native.sdk.c;
const acceptor = server.acceptor;
const tcp = server.tcp;

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

    const capacity = server.server.slotCapacity(&options, 1, 0);
    if (capacity == 0) return 2;
    var winsock = server.native.winsock.Winsock.init() catch return 2;
    defer winsock.deinit();
    const api = server.native.rio.Api.load() catch return 2;
    var failed = std.atomic.Value(bool).init(false);
    var worker: server.internal.TcpWorker = .{};
    var credits: [1]acceptor.AdmissionCredits = .{acceptor.AdmissionCredits.init(capacity)};
    tcp.initialize(&worker, &api, &options, &failed, 0, capacity, &credits[0]) catch return 2;
    if (!tcp.start(&worker)) {
        tcp.postAdmissionClosed(&worker);
        tcp.postStop(&worker);
        tcp.destroy(&worker);
        return 2;
    }

    var acceptor_value: acceptor.Acceptor = .{};
    const worker_slice: []server.internal.TcpWorker = @as([*]server.internal.TcpWorker, @ptrCast(&worker))[0..1];
    acceptor.initialize(&acceptor_value, &api, &options, worker_slice, credits[0..], &failed) catch {
        tcp.postAdmissionClosed(&worker);
        tcp.postStop(&worker);
        tcp.destroy(&worker);
        return 2;
    };
    if (!acceptor.start(&acceptor_value)) {
        acceptor.stop(&acceptor_value);
        acceptor.destroy(&acceptor_value);
        tcp.postAdmissionClosed(&worker);
        tcp.postStop(&worker);
        tcp.destroy(&worker);
        return 2;
    }

    c.Sleep(run_seconds * 1000);
    // The shutdown barrier, in the order server.zig uses it: the acceptor first, then admission,
    // then the workers, then the join.
    acceptor.stop(&acceptor_value);
    acceptor.destroy(&acceptor_value);
    tcp.postAdmissionClosed(&worker);
    tcp.postStop(&worker);
    tcp.join(&worker);
    const active = worker.engine_value.activeCount();
    const outstanding = worker.engine_value.outstanding();
    const pending_handoffs = credits[0].pending;
    tcp.destroy(&worker);

    var output_buffer: [192]u8 = undefined;
    const output = std.fmt.bufPrint(&output_buffer, "tcp_driver active={d} outstanding={d} handoffs={d} failed={s}\n", .{
        active,
        outstanding,
        pending_handoffs,
        if (failed.load(.acquire)) "true" else "false",
    }) catch return 4;
    if (!server.native.diagnostics.writeStdout(output)) return 4;
    if (active != 0 or outstanding != 0 or pending_handoffs != 0) return 2;
    return if (failed.load(.acquire)) 2 else 0;
}
