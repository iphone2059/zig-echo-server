const std = @import("std");
const internal = @import("engine_internal.zig");
const rio = @import("rio.zig");
const tcp_acceptor = @import("tcp_acceptor.zig");
const tcp_worker = @import("tcp_worker.zig");
const types = @import("types.zig");
const udp = @import("udp.zig");
const win32 = @import("win32.zig");
const c = win32.c;

pub const ShutdownPhase = enum { running, acceptor_stopped, admission_closed, workers_stopped, joined };

pub const ShutdownSequence = struct {
    phase: ShutdownPhase = .running,

    pub fn advance(self: *ShutdownSequence, next: ShutdownPhase) bool {
        const valid = switch (self.phase) {
            .running => next == .acceptor_stopped,
            .acceptor_stopped => next == .admission_closed,
            .admission_closed => next == .workers_stopped,
            .workers_stopped => next == .joined,
            .joined => false,
        };
        if (valid) self.phase = next;
        return valid;
    }
};

pub fn resolveWorkerCount(requested: u32, detected: u32) u32 {
    if (requested != 0) return requested;
    return std.math.clamp(detected, 1, 32);
}

pub fn formatTcpStatistics(buffer: []u8, statistics: *const internal.Statistics, elapsed_milliseconds: u64, active: u32) ![]u8 {
    const guarded_elapsed = @max(elapsed_milliseconds, 1);
    const mib_per_sec = (@as(f64, @floatFromInt(statistics.bytes)) * 1000.0) /
        (@as(f64, @floatFromInt(guarded_elapsed)) * 1024.0 * 1024.0);
    return std.fmt.bufPrint(buffer,
        "final protocol=tcp elapsed_ms={d} accepted={d} completions={d} receives={d} sends={d} bytes={d} MiB_per_sec={d:.2} active={d}\n",
        .{ elapsed_milliseconds, statistics.accepted, statistics.completions, statistics.receives, statistics.sends, statistics.bytes, mib_per_sec, active });
}

fn runTcp(api: *const rio.Api, options: *const types.Options, stop: *std.atomic.Value(bool)) types.ExitCode {
    const worker_count = resolveWorkerCount(options.worker_count, c.GetActiveProcessorCount(c.ALL_PROCESSOR_GROUPS));
    const allocator = std.heap.page_allocator;
    const workers = allocator.alloc(internal.Worker, worker_count) catch {
        win32.report("worker array allocation", c.ERROR_NOT_ENOUGH_MEMORY);
        return .network;
    };
    defer allocator.free(workers);
    const worker_resources = allocator.alloc(tcp_worker.WorkerResources, worker_count) catch {
        win32.report("worker resource allocation", c.ERROR_NOT_ENOUGH_MEMORY);
        return .network;
    };
    defer allocator.free(worker_resources);
    @memset(workers, .{});
    @memset(worker_resources, .{});

    var failed = std.atomic.Value(bool).init(false);
    var initialized: u32 = 0;
    var started: u32 = 0;
    for (workers, worker_resources, 0..) |*worker, *owned, index| {
        if (!tcp_worker.initializeWorker(worker, api, options, &failed, @intCast(index), worker_count, owned)) {
            failed.store(true, .release);
            tcp_worker.destroyWorker(worker);
            break;
        }
        initialized += 1;
        if (!tcp_worker.startWorker(worker)) {
            failed.store(true, .release);
            break;
        }
        started += 1;
    }

    var acceptor: internal.Acceptor = .{};
    var acceptor_resources: tcp_acceptor.AcceptorResources = .{};
    var acceptor_initialized = false;
    var acceptor_started = false;
    if (!failed.load(.acquire)) {
        acceptor_initialized = tcp_acceptor.initializeAcceptor(&acceptor, api, options, workers, &failed, &acceptor_resources);
        if (acceptor_initialized) acceptor_started = tcp_acceptor.startAcceptor(&acceptor);
        if (!acceptor_started) failed.store(true, .release);
    }

    const start = c.GetTickCount64();
    while (!failed.load(.acquire) and !stop.load(.acquire)) {
        if (options.run_seconds != 0 and c.GetTickCount64() - start >= @as(u64, options.run_seconds) * 1000) {
            stop.store(true, .release);
            break;
        }
        c.Sleep(10);
    }

    var shutdown: ShutdownSequence = .{};
    if (acceptor_started) tcp_acceptor.stopAcceptor(&acceptor);
    if (acceptor.resources != null) {
        tcp_acceptor.destroyAcceptor(&acceptor);
    }
    if (!shutdown.advance(.acceptor_stopped)) win32.failFast("TCP shutdown acceptor order", c.ERROR_INVALID_STATE);

    if (!acceptor_started) {
        for (workers[0..started]) |*worker| tcp_worker.postAdmissionClosed(worker);
    }
    if (!shutdown.advance(.admission_closed)) win32.failFast("TCP shutdown admission order", c.ERROR_INVALID_STATE);
    for (workers[0..started]) |*worker| tcp_worker.postStop(worker);
    if (!shutdown.advance(.workers_stopped)) win32.failFast("TCP shutdown worker order", c.ERROR_INVALID_STATE);

    var statistics: internal.Statistics = .{};
    var active: u32 = 0;
    for (workers[0..initialized]) |*worker| {
        tcp_worker.destroyWorker(worker);
        internal.statisticsAdd(&statistics, &worker.statistics);
        active += worker.active_count;
    }
    if (!shutdown.advance(.joined)) win32.failFast("TCP shutdown join order", c.ERROR_INVALID_STATE);
    if (active != 0) win32.failFast("TCP terminal active count", c.ERROR_IO_INCOMPLETE);

    if (options.stats) {
        var output_buffer: [512]u8 = undefined;
        const output = formatTcpStatistics(&output_buffer, &statistics, c.GetTickCount64() - start, active) catch
            win32.failFast("format TCP statistics", c.ERROR_INSUFFICIENT_BUFFER);
        if (!win32.writeStdout(output)) win32.failFast("write TCP statistics", c.GetLastError());
    }
    return if (failed.load(.acquire)) .network else .success;
}

pub fn runServer(options: *const types.Options, stop: *std.atomic.Value(bool)) types.ExitCode {
    var winsock = win32.Winsock.init() catch {
        win32.report("WSAStartup", @intCast(c.WSAGetLastError()));
        return .network;
    };
    defer winsock.deinit();
    var api = rio.Api.load() catch return .network;
    return switch (options.protocol) {
        .tcp => runTcp(&api, options, stop),
        .udp => udp.run(&api, options, stop),
        .none => .usage,
    };
}
