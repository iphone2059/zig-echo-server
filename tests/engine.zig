//! Server engine tests: the connection and TCP state machines, admission credits and worker
//! rotation, the acceptor state table, datagram semantics, the timer heap against a reference
//! model, per-slot registration isolation and the exact Windows ABI.

const std = @import("std");
const server = @import("server");
const c = server.native.sdk.c;
const acceptor = server.acceptor;
const connection = server.connection;
const tcp = server.tcp;
const types = server.types;
const udp = server.udp;

test "an adopted connection echoes and returns to receive" {
    var entry = connection.Connection.new(0);
    try std.testing.expect(entry.isIdle());
    try std.testing.expectEqual(connection.Step.receive, entry.admit(1_000, 5_000));
    try std.testing.expect(entry.isActive());
    try std.testing.expectEqual(@as(u64, 6_000), entry.deadline);

    const send = entry.onCompletion(.receive, types.error_success, 100, 1_100, 5_000);
    try std.testing.expectEqual(@as(u32, 100), send.send.length);
    try std.testing.expectEqual(@as(u32, 0), send.send.offset);

    const partial = entry.onCompletion(.send, types.error_success, 40, 1_200, 5_000);
    try std.testing.expectEqual(@as(u32, 40), partial.send.offset);
    try std.testing.expectEqual(@as(u32, 60), partial.send.length);

    try std.testing.expectEqual(connection.Step.receive, entry.onCompletion(.send, types.error_success, 60, 1_300, 5_000));
    try std.testing.expectEqual(connection.State.receiving, entry.state);
}

test "a zero-byte receive is an orderly shutdown and a reset closes" {
    var entry = connection.Connection.new(0);
    _ = entry.admit(0, 1_000);
    try std.testing.expectEqual(connection.Step.close_and_release, entry.onCompletion(.receive, types.error_success, 0, 1, 1_000));
    try std.testing.expectEqual(connection.State.released, entry.state);

    var second = connection.Connection.new(1);
    _ = second.admit(0, 1_000);
    try std.testing.expectEqual(connection.Step.close_and_release, second.onCompletion(.receive, types.wsa_econnreset, 0, 1, 1_000));
}

test "a closing connection waits for its outstanding operations" {
    var entry = connection.Connection.new(0);
    _ = entry.admit(0, 1_000);
    entry.outstanding = 2;
    try std.testing.expectEqual(connection.Step.close, entry.close());
    try std.testing.expect(entry.isClosing());
    try std.testing.expectEqual(connection.Step.none, entry.onCompletion(.receive, types.error_success, 8, 1, 1_000));
    try std.testing.expectEqual(connection.Step.close_and_release, entry.onCompletion(.send, types.error_success, 8, 2, 1_000));
    try std.testing.expectEqual(@as(u32, 0), entry.outstanding);
}

test "the engine drives a whole exchange and accounts for it" {
    var engine_value = try server.TcpEngine.init(4, 5_000);
    defer engine_value.deinit();
    const first = engine_value.adoptNext(1_000).?;
    try std.testing.expectEqual(@as(u32, 0), first.index());
    try std.testing.expectEqual(@as(u64, 6_000), first.receive.deadline);
    _ = engine_value.onCompletion(0, .receive, types.error_success, 64, 1_100);
    _ = engine_value.onCompletion(0, .send, types.error_success, 64, 1_200);
    try std.testing.expectEqual(@as(u64, 1), engine_value.statistics.accepted);
    try std.testing.expectEqual(@as(u64, 2), engine_value.statistics.completions);
    try std.testing.expectEqual(@as(u64, 1), engine_value.statistics.receives);
    try std.testing.expectEqual(@as(u64, 1), engine_value.statistics.sends);
    try std.testing.expectEqual(@as(u64, 64), engine_value.statistics.received_bytes);
    try std.testing.expectEqual(@as(u64, 64), engine_value.statistics.sent_bytes);
    try std.testing.expectEqual(@as(u64, 64), engine_value.statistics.bytes);
    try std.testing.expectEqual(@as(u64, 0), engine_value.statistics.network_errors);
}

test "a failed completion counts one network error and releases the slot" {
    var engine_value = try server.TcpEngine.init(2, 5_000);
    defer engine_value.deinit();
    _ = engine_value.adoptNext(0);
    const step = engine_value.onCompletion(0, .receive, types.wsa_econnreset, 0, 10).?;
    switch (step) {
        .release => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u64, 1), engine_value.statistics.network_errors);
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
    try std.testing.expectEqual(@as(u32, 0), engine_value.outstanding());
}

test "a refused post closes without waiting for a completion" {
    var engine_value = try server.TcpEngine.init(2, 5_000);
    defer engine_value.deinit();
    _ = engine_value.adoptNext(0);
    const step = engine_value.onPostFailure(0).?;
    switch (step) {
        .release => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u64, 1), engine_value.statistics.network_errors);
    try std.testing.expectEqual(@as(u32, 0), engine_value.outstanding());
}

test "timeouts close and the drain releases the slot" {
    var engine_value = try server.TcpEngine.init(4, 1_000);
    defer engine_value.deinit();
    var steps: [4]server.Step = undefined;
    _ = engine_value.adoptNext(100);
    try std.testing.expectEqual(@as(usize, 0), engine_value.onTimeout(1_099, &steps).len);
    const closing = engine_value.onTimeout(1_100, &steps);
    try std.testing.expectEqual(@as(usize, 1), closing.len);
    _ = engine_value.onCompletion(0, .receive, types.error_success, 0, 1_200);
    try std.testing.expectEqual(@as(u32, 0), engine_value.activeCount());
    engine_value.closeAdmission();
    try std.testing.expect(engine_value.mayExit());
}

test "an admission credit covers a connection that is still in transit" {
    var credit = acceptor.AdmissionCredits.init(3);
    try std.testing.expectEqual(@as(u32, 3), credit.capacity);
    try std.testing.expect(credit.isFull());
    try std.testing.expect(credit.tryReserve());
    try std.testing.expect(credit.tryReserve());
    try std.testing.expect(credit.tryReserve());
    // Three connections are in flight through the completion port, so there is no credit left even
    // though no worker has adopted a socket yet.
    try std.testing.expect(!credit.tryReserve());
    try std.testing.expect(!credit.isFull());
    // Adoption consumes the reservation; only releasing the connection returns the credit.
    credit.release();
    try std.testing.expect(credit.tryReserve());
    credit.release();
    credit.release();
    credit.release();
    try std.testing.expect(credit.isFull());
}

test "worker selection skips a saturated worker and rotates" {
    var credits = [_]acceptor.AdmissionCredits{
        acceptor.AdmissionCredits.init(1),
        acceptor.AdmissionCredits.init(1),
        acceptor.AdmissionCredits.init(1),
    };
    var rotation: u32 = 0;
    // Saturation is expressed by taking the credit away before the selection runs.
    try std.testing.expect(credits[1].tryReserve());
    try std.testing.expectEqual(@as(?u32, 0), acceptor.selectWorker(&credits, &rotation, 3));
    try std.testing.expectEqual(@as(?u32, 2), acceptor.selectWorker(&credits, &rotation, 3));
    // The two selections already spent the credits of workers 0 and 2.
    try std.testing.expect(acceptor.selectWorker(&credits, &rotation, 3) == null);
    credits[1].release();
    try std.testing.expectEqual(@as(?u32, 1), acceptor.selectWorker(&credits, &rotation, 3));
    try std.testing.expect(acceptor.selectWorker(&credits, &rotation, 3) == null);
    try std.testing.expect(acceptor.selectWorker(&credits, &rotation, 0) == null);
}

test "accept errors recover at the connection level" {
    try std.testing.expect(acceptor.acceptErrorIsRecoverable(64));
    try std.testing.expect(acceptor.acceptErrorIsRecoverable(types.wsa_econnreset));
    try std.testing.expect(acceptor.acceptErrorIsRecoverable(types.wsa_econnaborted));
    try std.testing.expect(!acceptor.acceptErrorIsRecoverable(types.error_not_enough_memory));
    try std.testing.expect(!acceptor.acceptErrorIsRecoverable(types.error_invalid_data));
}

test "the accept table only allows the documented transitions" {
    // The core owns the states and no native object, so the whole table is exercised without a
    // listener, a completion port or an operation record.
    var states: [1]acceptor.State = undefined;
    var core = acceptor.Core.init(&states);
    try std.testing.expect(core.transition(0, .idle, .posted));
    try std.testing.expectEqual(acceptor.State.posted, core.state(0).?);
    try std.testing.expect(!core.transition(0, .idle, .posted));
    try std.testing.expect(core.transition(0, .posted, .transit));
    try std.testing.expectEqual(acceptor.Action.wait_ack, core.actionFor(0));
    try std.testing.expect(core.transition(0, .transit, .idle));
    try std.testing.expectEqual(acceptor.Action.none, core.actionFor(0));
    // A posted operation may fall straight back to idle when its AcceptEx was refused or cancelled.
    try std.testing.expect(core.transition(0, .idle, .posted));
    try std.testing.expect(core.transition(0, .posted, .idle));
    try std.testing.expectEqual(acceptor.Action.none, core.actionFor(0));
    // A slot that spent its synchronous attempts yields to a queued repost. It is still live -- the
    // acceptor may not stop while one is outstanding -- and nothing is posted to cancel.
    try std.testing.expect(core.transition(0, .idle, .deferred));
    try std.testing.expectEqual(acceptor.Action.none, core.actionFor(0));
    try std.testing.expectEqual(@as(u32, 1), core.liveCount());
    try std.testing.expectEqual(@as(u32, 0), core.postedCount());
    try std.testing.expect(core.transition(0, .deferred, .idle));
    try std.testing.expectEqual(@as(u32, 0), core.liveCount());
    try std.testing.expect(!core.transition(0, .idle, .transit));
    try std.testing.expect(!core.transition(0, .deferred, .posted));
    // An index outside the table is refused rather than corrupting a neighbour.
    try std.testing.expect(!core.transition(9, .idle, .posted));
    try std.testing.expect(core.state(9) == null);
}

test "a zero-byte datagram is preserved and a reset recovers the receive depth" {
    // A completed receive always echoes the bytes it produced, including none at all.
    try std.testing.expectEqual(udp.Action.repost_send, udp.onCompletion(.receive, types.error_success, 0, 1024));
    try std.testing.expectEqual(udp.Action.repost_send, udp.onCompletion(.receive, types.error_success, 1024, 1024));
    try std.testing.expectEqual(udp.Action.repost_receive, udp.onCompletion(.send, types.error_success, 1024, 1024));
    // A reset restores the receive depth without echoing anything.
    try std.testing.expectEqual(udp.Action.repost_receive, udp.onCompletion(.receive, types.wsa_econnreset, 0, 1024));
    try std.testing.expectEqual(udp.Action.repost_receive, udp.onCompletion(.send, types.wsa_econnreset, 0, 1024));
    try std.testing.expectEqual(udp.Action.fatal, udp.onCompletion(.receive, types.error_invalid_data, 0, 1024));
    try std.testing.expectEqual(@as(u32, 0), udp.receiveLength(0, 1024));
    try std.testing.expectEqual(@as(u32, 1024), udp.receiveLength(4096, 1024));
}

test "the RIO request context round trips and rejects a forged value" {
    const encoded = server.worker.context.encode(7, .send);
    try std.testing.expect(encoded != 0);
    const decoded = server.worker.context.decode(encoded, 8).?;
    try std.testing.expectEqual(@as(u32, 7), decoded.index);
    try std.testing.expectEqual(types.EngineOperation.send, decoded.operation);
    const receive = server.worker.context.decode(server.worker.context.encode(3, .receive), 8).?;
    try std.testing.expectEqual(@as(u32, 3), receive.index);
    try std.testing.expectEqual(types.EngineOperation.receive, receive.operation);
    // A zero context and one that names a slot the worker does not own are both rejected.
    try std.testing.expect(server.worker.context.decode(0, 8) == null);
    try std.testing.expect(server.worker.context.decode(server.worker.context.encode(8, .receive), 8) == null);
    try std.testing.expect(server.worker.context.decode(1 << 40, 8) == null);
}

test "the datagram slot keeps its operation and length separately" {
    var slot = udp.Slot{};
    try std.testing.expectEqual(types.EngineOperation.receive, slot.operation);
    try std.testing.expect(!slot.outstanding);
    try std.testing.expectEqual(@as(u32, 0), slot.received_bytes);
    // The receive length is remembered exactly, so a zero-byte datagram stays zero bytes.
    slot.received_bytes = 0;
    slot.operation = .send;
    try std.testing.expectEqual(@as(u32, 0), udp.receiveLength(slot.received_bytes, 1024));
}

fn xorshift(state: *u32) u32 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    state.* = value;
    return value;
}

test "the timer heap agrees with a fixed-seed 100000-operation reference model" {
    const capacity = 64;
    var nodes: [capacity]server.timer.Node = undefined;
    var positions: [capacity]u32 = undefined;
    var active: [capacity]bool = @splat(false);
    var deadlines: [capacity]u64 = @splat(0);
    var heap = try server.timer.Heap.init(&nodes, &positions);
    var random_state: u32 = 0x9e3779b9;
    for (0..100000) |step| {
        const action = xorshift(&random_state) & 3;
        const index: u32 = xorshift(&random_state) % capacity;
        const now: u64 = step % 4096;
        if (action <= 1) {
            const deadline = xorshift(&random_state) % 4096;
            try std.testing.expect(heap.insertOrUpdate(index, deadline));
            active[index] = true;
            deadlines[index] = deadline;
        } else if (action == 2) {
            try std.testing.expect(active[index] == heap.remove(index));
            active[index] = false;
        } else {
            var expected: ?u32 = null;
            var best: u64 = 0;
            for (active, deadlines, 0..) |is_active, deadline, candidate| {
                if (is_active and deadline <= now and (expected == null or deadline < best or
                    (deadline == best and candidate < expected.?)))
                {
                    expected = @intCast(candidate);
                    best = deadline;
                }
            }
            try std.testing.expectEqual(expected, heap.popExpired(now));
            if (expected) |popped| active[popped] = false;
        }
        var count: u32 = 0;
        for (active, deadlines, 0..) |is_active, deadline, candidate| {
            if (!is_active) {
                try std.testing.expectEqual(server.timer.invalid_position, positions[candidate]);
                continue;
            }
            count += 1;
            try std.testing.expect(positions[candidate] < heap.len);
            try std.testing.expectEqual(@as(u32, @intCast(candidate)), nodes[positions[candidate]].index);
            try std.testing.expectEqual(deadline, nodes[positions[candidate]].deadline);
        }
        try std.testing.expectEqual(count, heap.len);
    }
}

test "each arena slot owns its own registration" {
    var winsock = try server.native.winsock.Winsock.init();
    defer winsock.deinit();
    const api = try server.native.rio.Api.load();
    try std.testing.expect(server.native.rio.Api.tableComplete(&api.table));
    var arena_value = try server.native.arena.Arena.create(&api, 4, 4096);
    defer arena_value.deinit();
    try std.testing.expectEqual(@as(usize, 4), arena_value.registrations.len);
    for (arena_value.registrations, 0..) |registration, index| {
        try std.testing.expect(registration.valid());
        for (arena_value.registrations[index + 1 ..]) |other| {
            try std.testing.expect(registration.id != other.id);
        }
    }
    // Views are bounds-checked against the slot stride, and the datagram path may ask for nothing.
    try std.testing.expect(arena_value.view(3, 0, 4096) != null);
    try std.testing.expect(arena_value.view(4, 0, 16) == null);
    try std.testing.expect(arena_value.view(0, 4000, 97) == null);
    try std.testing.expect(arena_value.view(0, 0, 0) == null);
    try std.testing.expect(arena_value.datagramView(0, 0, 0) != null);
    try std.testing.expect(arena_value.datagramView(0, 4096, 144) == null);
    try std.testing.expect(arena_value.slotBytes(3) != null);
    try std.testing.expect(arena_value.slotBytes(4) == null);
}

test "registered sockets require overlapped RIO and the ABI is exact" {
    try std.testing.expectEqual(c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO, server.native.socket.registeredFlags());
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.RIO_BUF));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.RIORESULT));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.OVERLAPPED));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.RIO_NOTIFICATION_COMPLETION));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(c.SYSTEM_INFO));
    try std.testing.expectEqual(@as(usize, 144), types.udp_address_bytes);
    // The datagram stride is the payload capacity plus the address area.
    try std.testing.expectEqual(@as(?u32, 144), server.native.arena.udpStride(0));
}

test "a worker refuses to release before its admission barrier and drain" {
    var lifecycle = types.WorkerLifecycle{ .phase = .quiescing, .notification_armed = true };
    try std.testing.expect(!types.workerMayExit(&lifecycle));
    lifecycle.phase = .admission_closed;
    try std.testing.expect(types.workerMayExit(&lifecycle));
    lifecycle.rio_outstanding = 1;
    try std.testing.expect(!types.workerMayExit(&lifecycle));
    lifecycle.rio_outstanding = 0;
    lifecycle.pending_handoffs = 1;
    try std.testing.expect(!types.workerMayExit(&lifecycle));
}

test "a live worker initializes, starts and releases cleanly" {
    var winsock = try server.native.winsock.Winsock.init();
    defer winsock.deinit();
    const api = try server.native.rio.Api.load();
    const options = types.Options{ .protocol = .tcp, .rio_buffer_bytes = 4096, .cq_capacity = 1024, .memory_bytes = 67_108_864 };
    var failed = std.atomic.Value(bool).init(false);
    var worker: server.internal.TcpWorker = .{};
    var credit = acceptor.AdmissionCredits.init(server.server.slotCapacity(&options, 1, 0));
    try std.testing.expect(credit.capacity > 0);
    try tcp.initialize(&worker, &api, &options, &failed, 0, credit.capacity, &credit);
    try std.testing.expect(tcp.start(&worker));
    try std.testing.expectEqual(credit.capacity, worker.engine_value.slotCount());
    tcp.postAdmissionClosed(&worker);
    tcp.postStop(&worker);
    tcp.join(&worker);
    // The terminal lifecycle is exact: every slot idle, nothing outstanding, admission closed.
    try std.testing.expect(worker.engine_value.mayExit());
    try std.testing.expectEqual(@as(u32, 0), worker.engine_value.activeCount());
    try std.testing.expectEqual(@as(u32, 0), worker.engine_value.outstanding());
    try std.testing.expectEqual(@as(u64, 0), worker.engine_value.statistics.accepted);
    tcp.destroy(&worker);
}

test "the terminal line keeps the reference field order for both protocols" {
    var statistics = types.Statistics{};
    statistics.accepted = 2;
    statistics.completions = 4;
    statistics.receives = 2;
    statistics.sends = 2;
    statistics.received_bytes = 128;
    statistics.sent_bytes = 128;
    statistics.bytes = 128;
    statistics.network_errors = 1;
    statistics.rejected = 3;
    var buffer: [512]u8 = undefined;
    const tcp_line = statistics.writeFinalLine(.tcp, 250, 2, 0, &buffer).?;
    try std.testing.expectEqualStrings(
        "final protocol=tcp elapsed_ms=250 workers=2 accepted=2 active=0 outstanding=0 completions=4 receives=2 sends=2 received_bytes=128 sent_bytes=128 bytes=128 network_errors=1 rejected=3 MiB_per_sec=0.00\n",
        tcp_line,
    );
    const udp_line = statistics.writeFinalLine(.udp, 250, 1, 4, &buffer).?;
    try std.testing.expect(std.mem.startsWith(u8, udp_line, "final protocol=udp elapsed_ms=250 workers=1 accepted=2 active=0 outstanding=4 "));
}


/// Reserves and immediately returns, which is the tightest possible contention on the one counter
/// the acceptor and the workers share.
fn creditChurn(credits: *acceptor.AdmissionCredits, iterations: u32, acquired: *u32) void {
    var taken: u32 = 0;
    var index: u32 = 0;
    while (index < iterations) : (index += 1) {
        if (credits.tryReserve()) {
            taken += 1;
            credits.release();
        }
    }
    acquired.* = taken;
}

/// Holds a batch the way in-flight handoffs do, then retires it together, so the compare-exchange
/// loop has to interleave with releases from the other threads.
fn creditHandoffChurn(credits: *acceptor.AdmissionCredits, attempts: u32, acquired: *u32) void {
    var held: u32 = 0;
    var index: u32 = 0;
    while (index < attempts) : (index += 1) {
        if (credits.tryReserve()) held += 1 else std.Thread.yield() catch {};
    }
    acquired.* = held;
    while (held != 0) : (held -= 1) credits.release();
}

test "admission credits stay exact under concurrent reserve and release" {
    // Four threads hammer one counter the way the acceptor and the workers do, and every thread
    // returns what it took. A non-atomic counter drifts here: it either loses credits, so the
    // final count falls short of the capacity, or it over-releases and trips the guard.
    var credits = acceptor.AdmissionCredits.init(8);
    var acquired: [4]u32 = @splat(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, &acquired) |*thread, *count| {
        thread.* = try std.Thread.spawn(.{}, creditChurn, .{ &credits, 50_000, count });
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expect(credits.isFull());
    var total: u64 = 0;
    for (acquired) |count| total += count;
    try std.testing.expect(total != 0);
}

test "admission credits survive concurrent handoff bursts and retirements" {
    // Every thread takes what it can and retires the whole batch afterwards, which is the shape of
    // an acceptor publishing handoffs while the workers finish connections.
    var credits = acceptor.AdmissionCredits.init(16);
    var acquired: [4]u32 = @splat(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, &acquired) |*thread, *count| {
        thread.* = try std.Thread.spawn(.{}, creditHandoffChurn, .{ &credits, 20_000, count });
    }
    for (&threads) |*thread| thread.join();
    try std.testing.expect(credits.isFull());
    var total: u64 = 0;
    for (acquired) |count| total += count;
    try std.testing.expect(total != 0);
}