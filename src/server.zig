//! Server entry point: Winsock, the RIO extension table, the protocol dispatch, the shutdown
//! barrier and the terminal summary.
//!
//! This is the counterpart of the reference's ces_run_server: RIO is loaded once through a probe
//! socket and every protocol runs against that table. There is no fallback data path.

const std = @import("std");
const acceptor = @import("internal.zig").acceptor;
const contract = @import("contract.zig");
const internal = @import("internal.zig");
const native = @import("native.zig");
const tcp = @import("internal.zig").worker.tcp;
const types = @import("types.zig");

const c = native.sdk.c;

/// Process-wide stop control. A console control handler can set it without a lock or an allocation.
var stop_requested = std.atomic.Value(bool).init(false);

pub fn requestStop() void {
    stop_requested.store(true, .release);
}

pub fn clearControl() void {
    stop_requested.store(false, .release);
}

/// The shutdown barrier. Every phase has to be reached in order, and the run only reports a clean
/// stop once the terminal counters agree with it.
pub const ShutdownPhase = enum(u8) { running, acceptor_stopped, admission_closed, workers_stopped, joined };

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

pub fn resolveWorkerCount(requested: u32) u32 {
    return types.resolvedWorkerCount(requested, native.activeProcessorCount());
}

/// The connection slots one worker can hold: half the completion queue, bounded by its page-rounded
/// share of the memory budget.
pub fn slotCapacity(options: *const types.Options, worker_count: u32, worker_index: u32) u32 {
    if (worker_count == 0 or options.rio_buffer_bytes == 0) return 0;
    const budget = contract.workerMemoryBudget(options.memory_bytes, worker_count, worker_index, native.pageBytes());
    return contract.tcpConnectionCapacity(options.cq_capacity, budget / options.rio_buffer_bytes);
}

/// A worker start that must fail on purpose. A real CreateThread refusal cannot be provoked from
/// outside, and the partial-startup cleanup path is the one place where a worker exists without a
/// thread; this stands in for it. Only the fault driver arms it, so a shipped binary always runs with
/// it unarmed and behaves identically.
var injected_start_failure: ?u32 = null;

/// Arms the injection above for the next run. Test-only.
pub fn injectWorkerStartFailure(index: ?u32) void {
    injected_start_failure = index;
}

/// The coordinator's worker ownership guard. After every thread is joined, a worker that did not
/// retire its operations still has registered memory and OVERLAPPED records Windows can reach, so
/// releasing it would be a use-after-free rather than a recoverable shutdown error.
pub fn requireWorkerRelease(running: bool, drained: bool) void {
    if (running and !drained) {
        native.diagnostics.failFast("TCP worker release precondition", c.ERROR_IO_INCOMPLETE);
    }
}

fn reportAndFail(stage: []const u8, native_error: u32) types.ExitCode {
    native.diagnostics.report(stage, native_error);
    return .network;
}

fn runTcp(api: *const native.rio.Api, options: *const types.Options) types.ExitCode {
    const allocator = std.heap.page_allocator;
    const worker_count = resolveWorkerCount(options.worker_count);
    var index: u32 = 0;
    while (index < worker_count) : (index += 1) {
        if (slotCapacity(options, worker_count, index) == 0) {
            return reportAndFail("TCP worker registered arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        }
    }

    const workers = allocator.alloc(internal.TcpWorker, worker_count) catch
        return reportAndFail("worker array allocation", c.ERROR_NOT_ENOUGH_MEMORY);
    defer allocator.free(workers);
    const credits = allocator.alloc(acceptor.AdmissionCredits, worker_count) catch
        return reportAndFail("worker array allocation", c.ERROR_NOT_ENOUGH_MEMORY);
    defer allocator.free(credits);
    for (workers) |*wrk| wrk.* = .{};
    for (credits, 0..) |*credit, position| {
        credit.* = acceptor.AdmissionCredits.init(slotCapacity(options, worker_count, @intCast(position)));
    }

    var failed = std.atomic.Value(bool).init(false);
    var initialized: u32 = 0;
    var started_workers: u32 = 0;
    for (workers, 0..) |*wrk, position| {
        switch (tcp.initializeResult(
            wrk,
            api,
            options,
            &failed,
            @intCast(position),
            credits[position].capacity,
            &credits[position],
        )) {
            .value => {},
            .failure => |failure| {
                native.diagnostics.reportFailure(failure);
                failed.store(true, .release);
                break;
            },
        }
        // Two different counts: initialized is the cleanup scope -- workers whose storage exists and
        // must be released -- while started_workers is the threads that actually run, which is what the
        // reference reports.
        initialized += 1;
        if (injected_start_failure) |failure_index| {
            if (failure_index == position) {
                // Stands in for a thread the operating system refused, one step after this worker's
                // storage exists and one step before it has a thread. The cleanup scope must still
                // cover it, and every worker that did start must still be joined.
                native.diagnostics.report("CreateThread(worker)", c.ERROR_NOT_ENOUGH_MEMORY);
                failed.store(true, .release);
                break;
            }
        }
        const started = tcp.start(wrk);
        if (wrk.thread.value != null) started_workers += 1;
        if (!started) {
            failed.store(true, .release);
            break;
        }
    }

    var acceptor_value: acceptor.Acceptor = .{};
    var acceptor_published = false;
    var startup_network_errors: u64 = 0;
    if (!failed.load(.acquire)) {
        switch (acceptor.initializeResult(&acceptor_value, api, options, workers[0..initialized], credits[0..initialized], &failed)) {
            .value => {},
            .failure => |failure| {
                native.diagnostics.reportFailure(failure);
                // Listener startup failures count even when no acceptor thread was created.
                if (failure.domain != .allocation) startup_network_errors +%= 1;
                failed.store(true, .release);
            },
        }
        if (!failed.load(.acquire)) {
            acceptor_published = acceptor.start(&acceptor_value);
            if (!acceptor_published) failed.store(true, .release);
        }
    }

    const start = native.nowMilliseconds();
    while (!failed.load(.acquire) and !stop_requested.load(.acquire)) {
        if (options.run_seconds != 0 and native.nowMilliseconds() - start >= @as(u64, options.run_seconds) * 1000) {
            stop_requested.store(true, .release);
            break;
        }
        c.Sleep(10);
    }

    var shutdown: ShutdownSequence = .{};
    // Phase one: stop and join every thread. Nothing in this phase may return early -- a thread still
    // running while the deferred release below frees its storage, its completion queue and its
    // registered memory is exactly the dangling ownership this barrier exists to prevent.
    if (acceptor_published) acceptor.stop(&acceptor_value);
    acceptor.join(&acceptor_value);
    if (!shutdown.advance(.acceptor_stopped)) native.diagnostics.failFast("TCP shutdown acceptor order", c.ERROR_INVALID_STATE);

    // The coordinator owns the admission barrier; the acceptor publishes nothing on its way out. A
    // run whose acceptor never started still has to close admission for the workers it did start.
    for (workers[0..initialized]) |*wrk| {
        if (wrk.thread.value != null) tcp.postAdmissionClosed(wrk);
    }
    if (!shutdown.advance(.admission_closed)) native.diagnostics.failFast("TCP shutdown admission order", c.ERROR_INVALID_STATE);

    for (workers[0..initialized]) |*wrk| {
        if (wrk.thread.value != null) tcp.postStop(wrk);
    }
    if (!shutdown.advance(.workers_stopped)) native.diagnostics.failFast("TCP shutdown worker order", c.ERROR_INVALID_STATE);

    var statistics = types.Statistics{};
    statistics.rejected +%= acceptor_value.core.rejected;
    statistics.network_errors +%= acceptor_value.core.network_errors +% startup_network_errors;
    var fatal = failed.load(.acquire);
    // Join the whole set before inspecting any release invariant.
    for (workers[0..initialized]) |*wrk| tcp.join(wrk);
    if (!shutdown.advance(.joined)) native.diagnostics.failFast("TCP shutdown join order", c.ERROR_INVALID_STATE);
    acceptor.requireRelease(&acceptor_value);
    var snapshots: [types.maximum_workers]types.NotifySnapshot = undefined;
    var snapshot_count: usize = 0;
    for (workers[0..initialized]) |*wrk| {
        tcp.requireRelease(wrk);
        statistics.merge(&wrk.engine_value.statistics);
        if (wrk.engine_value.fatal) fatal = true;
        if (wrk.ready) {
            snapshots[snapshot_count] = .{ .worker = wrk.worker_index, .arms = wrk.notification_arms, .deliveries = wrk.notification_deliveries, .timeout_wakeups = wrk.timeout_wakeups };
            snapshot_count += 1;
        }
    }

    // Every thread joined before the acceptor and worker ownership guards above. Each release
    // repeats its own guard, so no caller can free memory Windows can still reach.
    // Phase three: release, then assert the accounting that no longer implies native ownership.
    acceptor.destroy(&acceptor_value);
    for (workers[0..initialized]) |*wrk| tcp.destroy(wrk);
    native.diagnostics.writeSnapshots(snapshots[0..snapshot_count], .tcp);
    for (credits) |*credit| {
        if (!credit.isFull()) return reportAndFail("TCP acceptor terminal handoffs", c.ERROR_IO_INCOMPLETE);
    }

    const outstanding: u32 = 0;
    if (options.stats) {
        var buffer: [512]u8 = undefined;
        const line = statistics.writeFinalLine(.tcp, native.nowMilliseconds() - start, started_workers, outstanding, &buffer) orelse
            return reportAndFail("format TCP statistics", c.ERROR_INSUFFICIENT_BUFFER);
        _ = native.diagnostics.writeStdout(line);
    }
    return if (fatal or failed.load(.acquire)) .network else .success;
}

pub fn runServer(options: *const types.Options) types.ExitCode {
    var winsock = switch (native.winsock.Winsock.initResult()) {
        .value => |value| value,
        .failure => |failure| {
            native.diagnostics.reportFailure(failure);
            return .network;
        },
    };
    defer winsock.deinit();
    const api = switch (native.rio.Api.loadResult()) {
        .value => |value| value,
        .failure => |failure| {
            native.diagnostics.reportFailure(failure);
            return .network;
        },
    };
    return switch (options.protocol) {
        .tcp => runTcp(&api, options),
        .udp => internal.udp.runtime.run(&api, options, &stop_requested),
        .none => .usage,
    };
}

test "the shutdown barrier only advances in order" {
    var sequence: ShutdownSequence = .{};
    try std.testing.expect(!sequence.advance(.admission_closed));
    try std.testing.expect(sequence.advance(.acceptor_stopped));
    try std.testing.expect(!sequence.advance(.workers_stopped));
    try std.testing.expect(sequence.advance(.admission_closed));
    try std.testing.expect(sequence.advance(.workers_stopped));
    try std.testing.expect(sequence.advance(.joined));
    try std.testing.expect(!sequence.advance(.joined));
}

test "worker slot capacity is bounded by the queue and the memory budget" {
    const options = types.Options{ .rio_buffer_bytes = 16_384, .cq_capacity = 4_096, .memory_bytes = 1_073_741_824 };
    try std.testing.expectEqual(@as(u32, 2_048), slotCapacity(&options, 1, 0));
    // A 64 KiB budget holds exactly four 16 KiB slots, so the memory share caps the capacity.
    const tight = types.Options{ .rio_buffer_bytes = 16_384, .cq_capacity = 4_096, .memory_bytes = 65_536 };
    try std.testing.expectEqual(@as(u32, 4), slotCapacity(&tight, 1, 0));
    // A slot the budget cannot hold at all is refused rather than rounded down to nothing.
    const impossible = types.Options{ .rio_buffer_bytes = 1_048_576, .cq_capacity = 64, .memory_bytes = 1_048_576 };
    try std.testing.expectEqual(@as(u32, 0), slotCapacity(&impossible, 8, 7));
}
