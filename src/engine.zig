//! Per-worker TCP engine: connection slots, their deadlines, the free list, the lifecycle and the
//! statistics the worker reports.
//!
//! This is the aggregate the worker loop drives. It owns no native resource: every decision is
//! returned as a Step that the loop carries out through RIO, which keeps the whole echo progression
//! testable without a network. The counterpart of ces_engine_process_result in the C++ baseline.

const std = @import("std");
const internal = @import("internal.zig");
const types = @import("types.zig");

const Connection = internal.connection.Connection;
const ConnectionState = internal.connection.State;
const ConnectionStep = internal.connection.Step;
const TimerHeap = internal.worker.timer.Heap;

/// One decision the native layer has to carry out.
pub const Step = union(enum) {
    receive: struct { index: u32, deadline: u64 },
    send: struct { index: u32, offset: u32, length: u32, deadline: u64 },
    /// Close the socket; the slot still waits for the operations in flight.
    close: u32,
    /// Close the socket if needed and recycle the slot.
    release: u32,

    pub fn index(self: Step) u32 {
        return switch (self) {
            .receive => |value| value.index,
            .send => |value| value.index,
            .close => |value| value,
            .release => |value| value,
        };
    }
};

pub const InitError = error{ Capacity, Allocation, TimerHeap };

/// The bounded number of steps one decision can emit: one per connection slot.
pub fn stepCapacity(slot_count: u32) usize {
    return slot_count;
}

pub const TcpEngine = struct {
    const allocator = std.heap.page_allocator;

    connections: []Connection = &.{},
    free_indices: []u32 = &.{},
    free_count: u32 = 0,
    timer_nodes: []internal.worker.timer.Node = &.{},
    timer_positions: []u32 = &.{},
    timers: TimerHeap = .{},
    timeout_milliseconds: u64 = 0,
    active_connections: u32 = 0,
    rio_outstanding: u32 = 0,
    statistics: types.Statistics = .{},
    phase: types.WorkerPhase = .starting,
    stopping: bool = false,
    admission_closed: bool = false,
    notification_armed: bool = false,
    /// Set when a deadline could not be scheduled. Dropping a deadline would turn a timeout into a
    /// hang, so the worker fails fast instead.
    fatal: bool = false,

    pub fn init(slot_count: u32, timeout_milliseconds: u64) InitError!TcpEngine {
        if (slot_count == 0) return error.Capacity;
        var engine_value = TcpEngine{ .timeout_milliseconds = timeout_milliseconds };
        errdefer engine_value.deinit();
        engine_value.connections = allocator.alloc(Connection, slot_count) catch return error.Allocation;
        engine_value.free_indices = allocator.alloc(u32, slot_count) catch return error.Allocation;
        engine_value.timer_nodes = allocator.alloc(internal.worker.timer.Node, slot_count) catch return error.Allocation;
        engine_value.timer_positions = allocator.alloc(u32, slot_count) catch return error.Allocation;
        engine_value.timers = TimerHeap.init(engine_value.timer_nodes, engine_value.timer_positions) catch return error.TimerHeap;
        for (engine_value.connections, 0..) |*connection, index| connection.* = .{ .index = @intCast(index) };
        // The stack is filled so that the lowest free slot is handed out first.
        for (engine_value.free_indices, 0..) |*slot, index| slot.* = slot_count - @as(u32, @intCast(index)) - 1;
        engine_value.free_count = slot_count;
        return engine_value;
    }

    pub fn deinit(self: *TcpEngine) void {
        if (self.connections.len != 0) allocator.free(self.connections);
        if (self.free_indices.len != 0) allocator.free(self.free_indices);
        if (self.timer_nodes.len != 0) allocator.free(self.timer_nodes);
        if (self.timer_positions.len != 0) allocator.free(self.timer_positions);
        self.* = .{};
    }

    pub fn slotCount(self: *const TcpEngine) u32 {
        return @intCast(self.connections.len);
    }

    pub fn freeCount(self: *const TcpEngine) u32 {
        return self.free_count;
    }

    pub fn activeCount(self: *const TcpEngine) u32 {
        return self.active_connections;
    }

    pub fn outstanding(self: *const TcpEngine) u32 {
        return self.rio_outstanding;
    }

    pub fn connectionAt(self: *const TcpEngine, index: u32) ?*const Connection {
        if (index >= self.connections.len) return null;
        return &self.connections[index];
    }

    /// Ticks until the earliest armed deadline, or the infinite sentinel when none is armed.
    pub fn waitingMilliseconds(self: *const TcpEngine, now: u64) u32 {
        return self.timers.waitMilliseconds(now);
    }

    /// Takes the next free slot for an accepted socket. A stopping worker refuses new sockets, which
    /// is how admission drains without racing the acceptor.
    pub fn takeSlot(self: *TcpEngine) ?u32 {
        if (self.stopping) return null;
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const index = self.free_indices[self.free_count];
        if (index >= self.connections.len) {
            self.fatal = true;
            return null;
        }
        return index;
    }

    /// True while the worker is draining. A socket withdrawn then is a shutdown, not a capacity
    /// refusal, which is the distinction the reference makes when it counts rejected handoffs.
    pub fn isStopping(self: *const TcpEngine) bool {
        return self.stopping;
    }

    pub fn adoptNext(self: *TcpEngine, now: u64) ?Step {
        const index = self.takeSlot() orelse return null;
        return self.admit(index, now);
    }

    /// Gives a taken slot back without adopting it, used when the request queue could not be made.
    pub fn returnSlot(self: *TcpEngine, index: u32) void {
        if (index < self.connections.len) self.connections[index].state = .idle;
        self.pushFree(index);
    }

    /// Adopts a taken slot and arms its first receive.
    pub fn admit(self: *TcpEngine, index: u32, now: u64) ?Step {
        if (index >= self.connections.len) {
            self.fatal = true;
            return null;
        }
        const connection = &self.connections[index];
        _ = connection.admit(now, self.timeout_milliseconds);
        connection.outstanding +|= 1;
        self.statistics.accepted +%= 1;
        self.active_connections +|= 1;
        self.rio_outstanding +|= 1;
        self.schedule(index, connection.deadline);
        return .{ .receive = .{ .index = index, .deadline = connection.deadline } };
    }

    /// A posted operation completed.
    pub fn onCompletion(
        self: *TcpEngine,
        index: u32,
        operation: types.EngineOperation,
        status: i32,
        bytes: u32,
        now: u64,
    ) ?Step {
        if (index >= self.connections.len) {
            self.fatal = true;
            return null;
        }
        if (!self.connections[index].isActive()) {
            // A completion for a slot that is not in flight means the completion queue and the
            // connection table disagree; the baseline fails fast on exactly this.
            self.fatal = true;
            return null;
        }
        const connection = &self.connections[index];
        if (connection.outstanding == 0 or self.rio_outstanding == 0) {
            self.fatal = true;
            return null;
        }
        const closing = connection.isClosing();
        self.rio_outstanding -= 1;
        self.statistics.completions +%= 1;
        if (status == types.error_success) {
            // Count the native transfer, including successful completions that arrive during the
            // final drain. The bytes counter is successful echo sends only.
            const transferred: u64 = bytes;
            switch (operation) {
                .receive => {
                    self.statistics.receives +%= 1;
                    self.statistics.received_bytes +%= transferred;
                },
                .send => {
                    self.statistics.sends +%= 1;
                    self.statistics.sent_bytes +%= transferred;
                    self.statistics.bytes +%= transferred;
                },
            }
        } else if (!closing) {
            // A failed completion is a connection failure. Counting it here is what makes a peer
            // that resets report one error per established connection, exactly as the reference
            // does: that many operations were outstanding when the connection went away.
            self.statistics.network_errors +%= 1;
        }
        if (!closing and status == types.error_success and operation == .send and
            (bytes == 0 or connection.send_offset > connection.echo_bytes or
                bytes > connection.echo_bytes - connection.send_offset))
        {
            self.statistics.network_errors +%= 1;
        }
        const step = connection.onCompletion(operation, status, bytes, now, self.timeout_milliseconds);
        return self.apply(index, step);
    }

    /// A post was refused. Nothing was queued, so no completion will arrive and the connection can
    /// only be closed; this is the baseline's "a failed post is a session failure, not a process
    /// failure" rule.
    pub fn onPostFailure(self: *TcpEngine, index: u32) ?Step {
        self.statistics.network_errors +%= 1;
        if (self.rio_outstanding == 0) {
            self.fatal = true;
            return null;
        }
        self.rio_outstanding -= 1;
        if (index >= self.connections.len) {
            self.fatal = true;
            return null;
        }
        const connection = &self.connections[index];
        // The step that asked for this post already counted the operation, but RIO never queued it,
        // so the count has to come back down before the close.
        connection.outstanding -|= 1;
        return self.apply(index, connection.close());
    }

    /// Closes every connection whose deadline passed. The releases that were possible immediately
    /// are returned here; the rest arrive with their completions.
    pub fn onTimeout(self: *TcpEngine, now: u64, steps: []Step) []const Step {
        var count: usize = 0;
        while (self.timers.popExpired(now)) |index| {
            if (index >= self.connections.len) {
                self.fatal = true;
                continue;
            }
            const connection = &self.connections[index];
            if (!connection.isActive() or connection.isClosing()) continue;
            if (self.apply(index, connection.close())) |step| {
                if (count < steps.len) {
                    steps[count] = step;
                    count += 1;
                } else self.fatal = true;
            }
        }
        return steps[0..count];
    }

    /// Closes admission for this worker: no new socket is adopted and every live connection starts
    /// closing.
    pub fn beginStop(self: *TcpEngine, steps: []Step) []const Step {
        var count: usize = 0;
        if (self.stopping) return steps[0..0];
        self.stopping = true;
        self.phase = .draining;
        for (0..self.connections.len) |position| {
            const index: u32 = @intCast(position);
            if (!self.connections[position].isActive()) continue;
            if (self.apply(index, self.connections[position].close())) |step| {
                if (count < steps.len) {
                    steps[count] = step;
                    count += 1;
                } else self.fatal = true;
            }
        }
        return steps[0..count];
    }

    /// The admission barrier reached this worker.
    pub fn closeAdmission(self: *TcpEngine) void {
        self.admission_closed = true;
        if (@backingInt(self.phase) < @backingInt(types.WorkerPhase.admission_closed)) {
            self.phase = .admission_closed;
        }
    }

    pub fn lifecycle(self: *const TcpEngine) types.WorkerLifecycle {
        return .{
            .phase = self.phase,
            .active_connections = self.active_connections,
            .pending_handoffs = 0,
            .rio_outstanding = self.rio_outstanding,
            .notification_armed = self.notification_armed,
        };
    }

    /// A worker exits only after the admission barrier and a full drain, and only when its timer
    /// heap is empty: a leftover deadline would mean an unclosed connection.
    pub fn mayExit(self: *const TcpEngine) bool {
        const state = self.lifecycle();
        return types.workerMayExit(&state) and self.timers.len == 0;
    }

    fn pushFree(self: *TcpEngine, index: u32) void {
        if (self.free_count >= self.free_indices.len) {
            self.fatal = true;
            return;
        }
        self.free_indices[self.free_count] = index;
        self.free_count += 1;
    }

    fn apply(self: *TcpEngine, index: u32, step: ConnectionStep) ?Step {
        if (index >= self.connections.len) {
            self.fatal = true;
            return null;
        }
        const connection = &self.connections[index];
        switch (step) {
            .none => {
                // The operation in flight keeps its deadline.
                return null;
            },
            .receive => {
                connection.outstanding +|= 1;
                self.rio_outstanding +|= 1;
                self.schedule(index, connection.deadline);
                return .{ .receive = .{ .index = index, .deadline = connection.deadline } };
            },
            .send => |value| {
                connection.outstanding +|= 1;
                self.rio_outstanding +|= 1;
                self.schedule(index, connection.deadline);
                return .{ .send = .{
                    .index = index,
                    .offset = value.offset,
                    .length = value.length,
                    .deadline = connection.deadline,
                } };
            },
            .close => {
                _ = self.timers.remove(index);
                return .{ .close = index };
            },
            .close_and_release => {
                _ = self.timers.remove(index);
                connection.state = .idle;
                self.pushFree(index);
                if (self.active_connections == 0) {
                    self.fatal = true;
                    return null;
                }
                self.active_connections -= 1;
                return .{ .release = index };
            },
        }
    }

    fn schedule(self: *TcpEngine, index: u32, deadline: u64) void {
        if (!self.timers.insertOrUpdate(index, deadline)) self.fatal = true;
    }
};

test "an adopted connection echoes and returns to receive" {
    var engine_value = try TcpEngine.init(4, 5_000);
    defer engine_value.deinit();
    try std.testing.expectEqual(@as(u32, 4), engine_value.slotCount());
    try std.testing.expectEqual(@as(u32, 4), engine_value.freeCount());

    const first = engine_value.adoptNext(1_000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), first.index());
    try std.testing.expectEqual(@as(u32, 1), engine_value.activeCount());
    try std.testing.expectEqual(@as(u32, 1), engine_value.outstanding());
    try std.testing.expectEqual(@as(u64, 1), engine_value.statistics.accepted);

    // A receive completion turns into the echo send of exactly the bytes that arrived.
    const send = engine_value.onCompletion(0, .receive, types.error_success, 100, 1_100) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 100), send.send.length);
    try std.testing.expectEqual(@as(u32, 0), send.send.offset);
    try std.testing.expectEqual(@as(u64, 100), engine_value.statistics.received_bytes);

    // A partial send re-posts only the remainder.
    const partial = engine_value.onCompletion(0, .send, types.error_success, 40, 1_200) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 40), partial.send.offset);
    try std.testing.expectEqual(@as(u32, 60), partial.send.length);

    const next = engine_value.onCompletion(0, .send, types.error_success, 60, 1_300) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), next.index());
    switch (next) {
        .receive => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u64, 100), engine_value.statistics.bytes);
    try std.testing.expectEqual(@as(u64, 2), engine_value.statistics.sends);
}

test "a zero-byte receive is an orderly shutdown and releases the slot" {
    var engine_value = try TcpEngine.init(2, 5_000);
    defer engine_value.deinit();
    _ = engine_value.adoptNext(0);
    const step = engine_value.onCompletion(0, .receive, types.error_success, 0, 10) orelse return error.TestUnexpectedResult;
    switch (step) {
        .release => |index| try std.testing.expectEqual(@as(u32, 0), index),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
    try std.testing.expectEqual(@as(u32, 2), engine_value.freeCount());
    try std.testing.expectEqual(@as(u32, 0), engine_value.outstanding());
    // The slot is handed out again lowest first.
    const again = engine_value.adoptNext(20) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), again.index());
}

test "timeouts close and the drain releases the slot" {
    var engine_value = try TcpEngine.init(4, 1_000);
    defer engine_value.deinit();
    var steps: [4]Step = undefined;
    _ = engine_value.adoptNext(100);
    try std.testing.expectEqual(@as(u32, 1_100), engine_value.waitingMilliseconds(100) + 100);
    const expired = engine_value.onTimeout(1_099, &steps);
    try std.testing.expectEqual(@as(usize, 0), expired.len);
    const closing = engine_value.onTimeout(1_100, &steps);
    try std.testing.expectEqual(@as(usize, 1), closing.len);
    switch (closing[0]) {
        .close => |index| try std.testing.expectEqual(@as(u32, 0), index),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 1), engine_value.activeCount());
    const released = engine_value.onCompletion(0, .receive, types.wsa_econnreset, 0, 1_200) orelse return error.TestUnexpectedResult;
    switch (released) {
        .release => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
    // A completion for a connection that is already closing is retired without counting a fresh
    // failure: the connection failed when its deadline expired, and only once.
    try std.testing.expectEqual(@as(u64, 0), engine_value.statistics.network_errors);
    try std.testing.expect(engine_value.mayExit() == false);
    engine_value.closeAdmission();
    try std.testing.expect(engine_value.mayExit());
}

test "stopping drains every connection and closes admission" {
    var engine_value = try TcpEngine.init(3, 10_000);
    defer engine_value.deinit();
    var steps: [3]Step = undefined;
    _ = engine_value.adoptNext(0);
    _ = engine_value.adoptNext(0);
    const closing = engine_value.beginStop(&steps);
    try std.testing.expectEqual(@as(usize, 2), closing.len);
    try std.testing.expect(engine_value.isStopping());
    // A stopping worker refuses new handoffs, and the refusal is a shutdown rather than a capacity
    // error.
    try std.testing.expect(engine_value.takeSlot() == null);
    try std.testing.expectEqual(@as(usize, 0), engine_value.beginStop(&steps).len);
    _ = engine_value.onCompletion(0, .receive, types.error_success, 0, 10);
    _ = engine_value.onCompletion(1, .receive, types.error_success, 0, 10);
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
    engine_value.closeAdmission();
    try std.testing.expect(engine_value.mayExit());
}

test "slots are handed out lowest first and reused after release" {
    var engine_value = try TcpEngine.init(3, 10_000);
    defer engine_value.deinit();
    const first = engine_value.adoptNext(0).?;
    const second = engine_value.adoptNext(0).?;
    const third = engine_value.adoptNext(0).?;
    try std.testing.expectEqual(@as(u32, 0), first.index());
    try std.testing.expectEqual(@as(u32, 1), second.index());
    try std.testing.expectEqual(@as(u32, 2), third.index());
    try std.testing.expect(engine_value.adoptNext(0) == null);
    _ = engine_value.onCompletion(1, .receive, types.error_success, 0, 1);
    // A released index goes back on the stack and is handed out before the untouched ones.
    const reused = engine_value.adoptNext(2).?;
    try std.testing.expectEqual(@as(u32, 1), reused.index());
}

test "a refused post closes without waiting for a completion" {
    var engine_value = try TcpEngine.init(2, 10_000);
    defer engine_value.deinit();
    _ = engine_value.adoptNext(0);
    const before = engine_value.statistics.network_errors;
    const step = engine_value.onPostFailure(0) orelse return error.TestUnexpectedResult;
    switch (step) {
        .release => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(before + 1, engine_value.statistics.network_errors);
    try std.testing.expectEqual(@as(u32, 0), engine_value.outstanding());
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
}

test "invalid send progress counts a network error and releases" {
    var engine_value = try TcpEngine.init(2, 10_000);
    defer engine_value.deinit();
    _ = engine_value.adoptNext(0);
    _ = engine_value.onCompletion(0, .receive, types.error_success, 10, 1);
    const before = engine_value.statistics.network_errors;
    // A zero-byte successful send can never complete the echo.
    const step = engine_value.onCompletion(0, .send, types.error_success, 0, 2) orelse return error.TestUnexpectedResult;
    switch (step) {
        .release => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(before + 1, engine_value.statistics.network_errors);
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
}

test "the final line matches the worker counters" {
    var engine_value = try TcpEngine.init(2, 10_000);
    defer engine_value.deinit();
    _ = engine_value.adoptNext(0);
    _ = engine_value.onCompletion(0, .receive, types.error_success, 16, 1);
    _ = engine_value.onCompletion(0, .send, types.error_success, 16, 2);
    var buffer: [512]u8 = undefined;
    const line = engine_value.statistics.writeFinalLine(.tcp, 1_000, 1, engine_value.outstanding(), &buffer).?;
    var expected: [512]u8 = undefined;
    const expected_text = try std.fmt.bufPrint(&expected,
        "final protocol=tcp elapsed_ms=1000 workers=1 accepted=1 active=0 outstanding=1 completions=2 receives=1 sends=1 received_bytes=16 sent_bytes=16 bytes=16 network_errors=0 rejected=0 MiB_per_sec=0.00\n", .{});
    try std.testing.expectEqualStrings(expected_text, line);
}
