//! Shared server vocabulary: protocol, exit codes, parsed options, worker lifecycle and the
//! engine statistics the terminal report is derived from.
//!
//! Every name mirrors the C++ baseline (ces_types.h / internal.h) and the Rust server so the
//! implementations share one contract.

const std = @import("std");

pub const Protocol = enum(u8) { none = 0, tcp = 1, udp = 2 };

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    network = 2,
    /// Declared for parity with the exit-code contract; the server never classifies an echo
    /// failure of its own.
    echo_failure = 3,
    internal = 4,
};

pub const default_port: u16 = 7;
pub const default_tcp_timeout_seconds: u32 = 300;
pub const default_udp_depth: u32 = 256;
pub const default_rio_buffer_bytes: u32 = 16_384;
pub const default_cq_capacity: u32 = 4_096;
pub const default_memory_bytes: u64 = 1_073_741_824;
pub const maximum_udp_payload: u64 = 65_507;

/// A saturated peer can keep a completion queue non-empty indefinitely, so a drain yields to the
/// control path after this many batches.
pub const completion_batch_size: u32 = 256;
pub const completion_drain_batches: u32 = 64;

/// AcceptEx requires a SOCKADDR_STORAGE plus sixteen bytes of padding per address.
pub const sockaddr_storage_bytes: usize = 128;
pub const accept_address_bytes: usize = sockaddr_storage_bytes + 16;
pub const accept_operation_bytes: usize = accept_address_bytes * 2;
/// A UDP slot carries the payload and one address area.
pub const udp_address_bytes: usize = sockaddr_storage_bytes + 16;

/// The worker switch accepts 0..=64; zero uses the active processor count capped at 64.
pub const maximum_workers: u32 = 64;
pub const automatic_worker_cap: u32 = maximum_workers;

/// IOCP completion keys that are not accept operations. An accept operation is identified by its
/// own address, which is always larger than both control keys.
pub const stop_key: usize = 1;
pub const admission_closed_key: usize = 2;

pub const error_capacity: usize = 256;

/// Native status codes referenced by name.
pub const error_success: i32 = 0;
pub const error_not_enough_memory: i32 = 8;
pub const error_invalid_data: i32 = 13;
pub const error_netname_deleted: u32 = 64;
pub const error_io_incomplete: i32 = 996;
pub const error_io_pending: i32 = 997;
pub const wsa_econnaborted: i32 = 10_053;
pub const wsa_econnreset: i32 = 10_054;
pub const wait_object_0: u32 = 0;
pub const wait_timeout: u32 = 258;
/// winbase.h INFINITE, passed to GetQueuedCompletionStatus and WaitForSingleObject.
pub const infinite: u32 = 0xffff_ffff;

pub const Options = struct {
    protocol: Protocol = .none,
    port: u16 = default_port,
    timeout_seconds: u32 = default_tcp_timeout_seconds,
    run_seconds: u32 = 0,
    socket_buffer_bytes: u32 = 0,
    udp_depth: u32 = default_udp_depth,
    worker_count: u32 = 0,
    rio_buffer_bytes: u32 = default_rio_buffer_bytes,
    cq_capacity: u32 = default_cq_capacity,
    memory_bytes: u64 = default_memory_bytes,
    /// Accepted for command-line parity with the baseline, which also never reads it: the server
    /// prints nothing outside the statistics switch.
    quiet: bool = false,
    stats: bool = false,
    help: bool = false,
};

/// Worker lifecycle states in the baseline's order. Every phase at or past admission_closed
/// releases the worker from the admission barrier.
pub const WorkerPhase = enum(u8) {
    starting = 0,
    running = 1,
    quiescing = 2,
    admission_closed = 3,
    draining = 4,
    stopped = 5,
};

pub const WorkerLifecycle = struct {
    phase: WorkerPhase = .starting,
    active_connections: u32 = 0,
    pending_handoffs: u32 = 0,
    /// RIO requests must retire before the completion queue can be closed; a pending notification
    /// delivery does not hold the worker open once this reaches zero.
    rio_outstanding: u32 = 0,
    notification_armed: bool = false,
};

/// A worker may only be released once admission is closed, every accepted socket and pending
/// handoff has drained, and every RIO request has retired.
pub fn workerMayExit(lifecycle: *const WorkerLifecycle) bool {
    return @backingInt(lifecycle.phase) >= @backingInt(WorkerPhase.admission_closed) and
        lifecycle.active_connections == 0 and
        lifecycle.pending_handoffs == 0 and
        lifecycle.rio_outstanding == 0;
}

pub const UdpPhase = enum(u8) { running = 0, draining = 1, stopped = 2 };

/// Registered UDP storage is released only after the phase reached stopped and every posted
/// request has completed.
pub fn udpMayRelease(phase: UdpPhase, outstanding: u32) bool {
    return phase == .stopped and outstanding == 0;
}

/// What a completion belongs to. The operation travels in the RIO request context, so a completion
/// for a connection that was already closed is still classified correctly.
pub const EngineOperation = enum(u8) { receive, send };

/// Counters accumulated by one worker (TCP) or by the single UDP engine.
pub const Statistics = struct {
    accepted: u64 = 0,
    completions: u64 = 0,
    receives: u64 = 0,
    sends: u64 = 0,
    /// Bytes reported by successful native receive completions.
    received_bytes: u64 = 0,
    /// Bytes reported by successful native send completions.
    sent_bytes: u64 = 0,
    bytes: u64 = 0,
    /// Failures at the connection or accept layer, plus the connects refused for capacity.
    network_errors: u64 = 0,
    rejected: u64 = 0,

    /// Wrapping addition: the baseline reports exact 64-bit totals, so a counter that saturated
    /// would silently under-report.
    pub fn merge(self: *Statistics, other: *const Statistics) void {
        self.accepted +%= other.accepted;
        self.completions +%= other.completions;
        self.receives +%= other.receives;
        self.sends +%= other.sends;
        self.received_bytes +%= other.received_bytes;
        self.sent_bytes +%= other.sent_bytes;
        self.bytes +%= other.bytes;
        self.network_errors +%= other.network_errors;
        self.rejected +%= other.rejected;
    }

    /// The aggregate terminal line, in the reference's field order for both protocols: the only
    /// differences between them are the protocol name and the value of outstanding. Active is
    /// reported as the reference reports it, which is always zero because every worker has joined
    /// before the line is printed. The rate is guarded against a zero-millisecond run.
    pub fn writeFinalLine(
        self: *const Statistics,
        protocol: Protocol,
        elapsed_milliseconds: u64,
        worker_count: u32,
        outstanding: u32,
        buffer: []u8,
    ) ?[]const u8 {
        const guarded = @max(elapsed_milliseconds, 1);
        const rate = @as(f64, @floatFromInt(self.bytes)) / (1024.0 * 1024.0) /
            (@as(f64, @floatFromInt(guarded)) / 1000.0);
        const name = if (protocol == .udp) "udp" else "tcp";
        return std.fmt.bufPrint(
            buffer,
            "final protocol={s} elapsed_ms={d} workers={d} accepted={d} active=0 outstanding={d} completions={d} receives={d} sends={d} received_bytes={d} sent_bytes={d} bytes={d} network_errors={d} rejected={d} MiB_per_sec={d:.2}\n",
            .{
                name,
                elapsed_milliseconds,
                worker_count,
                self.accepted,
                outstanding,
                self.completions,
                self.receives,
                self.sends,
                self.received_bytes,
                self.sent_bytes,
                self.bytes,
                self.network_errors,
                self.rejected,
                rate,
            },
        ) catch null;
    }
};

/// Optional notification observability, copied only once the owning loop has stopped.
pub const NotifySnapshot = struct {
    worker: u32 = 0,
    arms: u64 = 0,
    deliveries: u64 = 0,
    timeout_wakeups: u64 = 0,

    pub fn valid(self: *const NotifySnapshot) bool {
        return self.timeout_wakeups == 0 and self.arms >= self.deliveries and self.arms - self.deliveries <= 1;
    }
};

/// Resolves the worker switch, or the automatic count when it is absent. The processor count is
/// passed in so the rule is testable without querying the machine.
pub fn resolvedWorkerCount(worker_count: u32, processors: u32) u32 {
    if (worker_count != 0) return worker_count;
    return std.math.clamp(processors, 1, automatic_worker_cap);
}

/// Overflow-checked arithmetic as a compile-time type generic.
pub fn checkedProduct(comptime T: type, left: T, right: T) ?T {
    const pair = @mulWithOverflow(left, right);
    return if (pair[1] == 0) pair[0] else null;
}

pub fn checkedAdd(comptime T: type, left: T, right: T) ?T {
    const pair = @addWithOverflow(left, right);
    return if (pair[1] == 0) pair[0] else null;
}

pub fn ceilingDivide(comptime T: type, numerator: T, denominator: T) T {
    if (denominator == 0) return numerator;
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

test "worker resolution matches the baseline bounds" {
    try std.testing.expectEqual(@as(u32, 4), resolvedWorkerCount(4, 8));
    try std.testing.expectEqual(@as(u32, 16), resolvedWorkerCount(0, 16));
    try std.testing.expectEqual(@as(u32, 1), resolvedWorkerCount(0, 0));
    try std.testing.expectEqual(automatic_worker_cap, resolvedWorkerCount(0, 128));
    try std.testing.expectEqual(maximum_workers, resolvedWorkerCount(maximum_workers, 128));
    // An explicit zero is "automatic", not "no workers".
    try std.testing.expectEqual(@as(u32, 8), resolvedWorkerCount(0, 8));
}

test "the lifecycle requires the admission barrier and a full drain" {
    var lifecycle = WorkerLifecycle{ .phase = .quiescing, .notification_armed = true };
    try std.testing.expect(!workerMayExit(&lifecycle));
    lifecycle.phase = .admission_closed;
    try std.testing.expect(workerMayExit(&lifecycle));
    lifecycle.pending_handoffs = 1;
    try std.testing.expect(!workerMayExit(&lifecycle));
    lifecycle.pending_handoffs = 0;
    lifecycle.active_connections = 1;
    try std.testing.expect(!workerMayExit(&lifecycle));
    lifecycle.active_connections = 0;
    lifecycle.rio_outstanding = 1;
    try std.testing.expect(!workerMayExit(&lifecycle));
    lifecycle.phase = .stopped;
    try std.testing.expect(!workerMayExit(&lifecycle));
    lifecycle.rio_outstanding = 0;
    try std.testing.expect(workerMayExit(&lifecycle));
}

test "UDP storage is released only after the final completion" {
    try std.testing.expect(!udpMayRelease(.running, 0));
    try std.testing.expect(!udpMayRelease(.draining, 0));
    try std.testing.expect(!udpMayRelease(.stopped, 1));
    try std.testing.expect(udpMayRelease(.stopped, 0));
}

test "statistics aggregate exactly and format like the baseline" {
    var total = Statistics{};
    total.merge(&.{ .accepted = 3, .completions = 11, .receives = 5, .sends = 6, .bytes = 4096 });
    total.merge(&.{ .accepted = 7, .completions = 19, .receives = 9, .sends = 10, .bytes = 8192 });
    try std.testing.expectEqual(@as(u64, 10), total.accepted);
    try std.testing.expectEqual(@as(u64, 30), total.completions);
    try std.testing.expectEqual(@as(u64, 14), total.receives);
    try std.testing.expectEqual(@as(u64, 16), total.sends);
    try std.testing.expectEqual(@as(u64, 12_288), total.bytes);
    var buffer: [512]u8 = undefined;
    const line = total.writeFinalLine(.tcp, 500, 4, 0, &buffer).?;
    try std.testing.expectEqualStrings(
        "final protocol=tcp elapsed_ms=500 workers=4 accepted=10 active=0 outstanding=0 completions=30 receives=14 sends=16 received_bytes=0 sent_bytes=0 bytes=12288 network_errors=0 rejected=0 MiB_per_sec=0.02\n",
        line,
    );
    // A zero-millisecond run is guarded to one millisecond.
    const udp_line = total.writeFinalLine(.udp, 0, 1, 3, &buffer).?;
    try std.testing.expectEqualStrings(
        "final protocol=udp elapsed_ms=0 workers=1 accepted=10 active=0 outstanding=3 completions=30 receives=14 sends=16 received_bytes=0 sent_bytes=0 bytes=12288 network_errors=0 rejected=0 MiB_per_sec=11.72\n",
        udp_line,
    );
    // Large values wrap exactly instead of saturating, matching the baseline counters.
    var large = Statistics{ .accepted = std.math.maxInt(u64) - 100, .bytes = std.math.maxInt(u64) - 4096 };
    large.merge(&.{ .accepted = 100, .bytes = 4096 });
    try std.testing.expectEqual(std.math.maxInt(u64), large.accepted);
    try std.testing.expectEqual(std.math.maxInt(u64), large.bytes);
}

test "a notification snapshot allows only one pending real delivery" {
    var snapshot = NotifySnapshot{ .worker = 3, .arms = 7, .deliveries = 6 };
    try std.testing.expect(snapshot.valid());
    snapshot.deliveries = 5;
    try std.testing.expect(!snapshot.valid());
    snapshot.deliveries = 8;
    try std.testing.expect(!snapshot.valid());
    snapshot.deliveries = 7;
    snapshot.timeout_wakeups = 1;
    try std.testing.expect(!snapshot.valid());
}
