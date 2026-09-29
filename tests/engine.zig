const std = @import("std");
const server = @import("server");
const win32 = server.win32;
const rio = server.rio;
const c = win32.c;
const timer_heap = server.timer_heap;
const internal = server.engine_internal;
const tcp_worker = server.tcp_worker;

test "Win32 owner transfer and reset are idempotent" {
    var socket: win32.Socket = .{};
    try std.testing.expectEqual(c.INVALID_SOCKET, socket.get());
    try std.testing.expectEqual(c.INVALID_SOCKET, socket.take());
    socket.reset(c.INVALID_SOCKET);
    socket.deinit();

    var handle: win32.Handle = .{};
    try std.testing.expect(handle.get() == null);
    try std.testing.expect(handle.take() == null);
    handle.reset(null);
    handle.deinit();

    var memory = try win32.VirtualMemory.alloc(4096);
    const pointer = memory.take();
    try std.testing.expect(pointer != null);
    try std.testing.expect(memory.get() == null);
    memory.reset(pointer);
    memory.deinit();
    memory.deinit();

    var thread: win32.ThreadHandle = .{};
    var event: win32.EventHandle = .{};
    thread.deinit();
    event.deinit();
}

test "registered sockets always request overlapped RIO" {
    try std.testing.expectEqual(c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO, win32.registeredSocketFlags());
}

test "RIO table validation rejects missing entries and accepts loaded table" {
    var empty: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
    try std.testing.expect(!rio.Api.tableComplete(&empty));

    var winsock = try win32.Winsock.init();
    defer winsock.deinit();
    const api = try rio.Api.load();
    try std.testing.expect(rio.Api.tableComplete(&api.table));
}

test "project-private Windows ABI declarations retain required sizes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.GUID));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(c.RIO_BUF));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(c.RIORESULT));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.OVERLAPPED));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(c.RIO_NOTIFICATION_COMPLETION));
}

test "worker and UDP lifecycle retain storage until terminal barriers" {
    var lifecycle: internal.WorkerLifecycle = .{
        .phase = .quiescing,
        .active_connections = 0,
        .pending_handoffs = 0,
        .notification_armed = true,
    };
    try std.testing.expect(!internal.workerMayExit(&lifecycle));
    lifecycle.phase = .admission_closed;
    try std.testing.expect(internal.workerMayExit(&lifecycle));
    lifecycle.pending_handoffs = 1;
    try std.testing.expect(!internal.workerMayExit(&lifecycle));
    lifecycle.pending_handoffs = 0;
    lifecycle.active_connections = 1;
    try std.testing.expect(!internal.workerMayExit(&lifecycle));
    try std.testing.expect(!internal.udpMayRelease(.draining, 0));
    try std.testing.expect(!internal.udpMayRelease(.stopped, 1));
    try std.testing.expect(internal.udpMayRelease(.stopped, 0));

    var expected: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    var other: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    try std.testing.expect(internal.notificationPacketMatches(7, &expected, 7, &expected));
    try std.testing.expect(!internal.notificationPacketMatches(8, &expected, 7, &expected));
    try std.testing.expect(!internal.notificationPacketMatches(7, &other, 7, &expected));
}

test "statistics aggregate exact large values" {
    var total: internal.Statistics = .{};
    internal.statisticsAdd(&total, &.{ .accepted = 3, .completions = 11, .receives = 5, .sends = 6, .bytes = 4096 });
    internal.statisticsAdd(&total, &.{ .accepted = 7, .completions = 19, .receives = 9, .sends = 10, .bytes = 8192 });
    try std.testing.expectEqual(@as(u64, 10), total.accepted);
    try std.testing.expectEqual(@as(u64, 30), total.completions);
    try std.testing.expectEqual(@as(u64, 12288), total.bytes);

    var large: internal.Statistics = .{ .accepted = std.math.maxInt(u64) - 100, .bytes = std.math.maxInt(u64) - 4096 };
    internal.statisticsAdd(&large, &.{ .accepted = 100, .bytes = 4096 });
    try std.testing.expectEqual(std.math.maxInt(u64), large.accepted);
    try std.testing.expectEqual(std.math.maxInt(u64), large.bytes);
}

test "timer exposes exact deadlines ordering and DWORD saturation" {
    var nodes: [4]timer_heap.Node = undefined;
    var positions: [4]u32 = undefined;
    var heap = try timer_heap.Heap.init(&nodes, &positions);
    try std.testing.expectEqual(c.INFINITE, heap.waitMilliseconds(10));
    try std.testing.expect(heap.insertOrUpdate(2, 40));
    try std.testing.expect(heap.insertOrUpdate(1, 20));
    try std.testing.expect(heap.insertOrUpdate(3, 30));
    try std.testing.expectEqual(@as(u32, 10), heap.waitMilliseconds(10));
    try std.testing.expect(heap.insertOrUpdate(2, 15));
    try std.testing.expectEqual(@as(?u32, 2), heap.popExpired(15));
    try std.testing.expect(heap.remove(1));
    try std.testing.expectEqual(@as(u32, 10), heap.waitMilliseconds(20));
    try std.testing.expect(!heap.insertOrUpdate(4, 1));
    try std.testing.expect(heap.remove(3));
    try std.testing.expect(heap.insertOrUpdate(3, 50));
    try std.testing.expect(heap.insertOrUpdate(1, 50));
    try std.testing.expectEqual(@as(?u32, 1), heap.popExpired(50));
    try std.testing.expect(heap.remove(3));
    try std.testing.expect(heap.insertOrUpdate(0, std.math.maxInt(u64)));
    try std.testing.expectEqual(c.INFINITE - 1, heap.waitMilliseconds(0));
}

fn xorshift(state: *u32) u32 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    state.* = value;
    return value;
}

test "timer matches fixed-seed reference model for 100000 operations" {
    const capacity = 64;
    var nodes: [capacity]timer_heap.Node = undefined;
    var positions: [capacity]u32 = undefined;
    var active: [capacity]bool = @splat(false);
    var deadlines: [capacity]u64 = @splat(0);
    var heap = try timer_heap.Heap.init(&nodes, &positions);
    var random_state: u32 = 0x51A7E123;

    for (0..100000) |step| {
        const operation = xorshift(&random_state) & 3;
        const connection_index: u32 = xorshift(&random_state) % capacity;
        const now: u64 = step % 4096;
        if (operation <= 1) {
            const deadline = xorshift(&random_state) % 4096;
            try std.testing.expect(heap.insertOrUpdate(connection_index, deadline));
            active[connection_index] = true;
            deadlines[connection_index] = deadline;
        } else if (operation == 2) {
            const expected = active[connection_index];
            try std.testing.expectEqual(expected, heap.remove(connection_index));
            if (expected) active[connection_index] = false;
        } else {
            var expected_index: ?u32 = null;
            var expected_deadline: u64 = 0;
            for (active, deadlines, 0..) |is_active, deadline, index| {
                if (is_active and deadline <= now and (expected_index == null or deadline < expected_deadline or
                    (deadline == expected_deadline and index < expected_index.?)))
                {
                    expected_index = @intCast(index);
                    expected_deadline = deadline;
                }
            }
            const popped = heap.popExpired(now);
            try std.testing.expectEqual(expected_index, popped);
            if (expected_index) |index| active[index] = false;
        }

        var active_count: u32 = 0;
        var minimum_index: ?u32 = null;
        var minimum_deadline: u64 = 0;
        for (active, deadlines, 0..) |is_active, deadline, index| {
            if (!is_active) {
                try std.testing.expectEqual(timer_heap.invalid_position, positions[index]);
                continue;
            }
            active_count += 1;
            const position = positions[index];
            try std.testing.expect(position < heap.len);
            try std.testing.expectEqual(@as(u32, @intCast(index)), nodes[position].index);
            try std.testing.expectEqual(deadline, nodes[position].deadline);
            if (minimum_index == null or deadline < minimum_deadline or
                (deadline == minimum_deadline and index < minimum_index.?))
            {
                minimum_index = @intCast(index);
                minimum_deadline = deadline;
            }
        }
        try std.testing.expectEqual(active_count, heap.len);
        if (minimum_index) |index| {
            try std.testing.expectEqual(index, nodes[0].index);
            try std.testing.expectEqual(minimum_deadline, nodes[0].deadline);
        }
        const expected_wait: u32 = if (minimum_index == null)
            c.INFINITE
        else if (minimum_deadline <= now)
            0
        else
            @intCast(@min(minimum_deadline - now, @as(u64, c.INFINITE - 1)));
        try std.testing.expectEqual(expected_wait, heap.waitMilliseconds(now));
    }
}

test "published request and accept contexts validate stable owner ranges" {
    var connections: [2]internal.Connection = .{ .{}, .{} };
    connections[0].request.connection = &connections[0];
    connections[1].request.connection = &connections[1];
    try std.testing.expect(internal.requestContextValid(&connections[0].request, &connections));
    var foreign_connection: internal.Connection = .{};
    foreign_connection.request.connection = &foreign_connection;
    try std.testing.expect(!internal.requestContextValid(&foreign_connection.request, &connections));

    var acceptor: internal.Acceptor = .{};
    var accepts: [2]internal.AcceptOperation = .{ .{}, .{} };
    accepts[0].owner = &acceptor;
    try std.testing.expect(internal.acceptContextValid(&accepts[0], &accepts, &acceptor));
    try std.testing.expect(!internal.acceptContextValid(&accepts[1], &accepts, &acceptor));
}

test "TCP worker capacity is bounded by CQ and per-worker registered memory" {
    var options: server.types.Options = .{
        .rio_buffer_bytes = 4096,
        .cq_capacity = 1024,
        .memory_bytes = 4096 * 100,
    };
    try std.testing.expectEqual(@as(?u32, 50), tcp_worker.connectionCapacity(&options, 2));
    options.memory_bytes = 4096 * 8;
    try std.testing.expectEqual(@as(?u32, 1), tcp_worker.connectionCapacity(&options, 8));
    options.memory_bytes = 0;
    try std.testing.expectEqual(@as(?u32, null), tcp_worker.connectionCapacity(&options, 8));
}

test "TCP worker free stack exhausts and restores exact connection index" {
    var connections: [2]internal.Connection = .{ .{ .index = 0 }, .{ .index = 1 } };
    var free_indices: [2]u32 = .{ 0, 1 };
    var worker: internal.Worker = .{
        .connections = &connections,
        .free_indices = &free_indices,
        .slot_count = 2,
        .free_count = 2,
    };
    const first = tcp_worker.acquireConnection(&worker).?;
    const second = tcp_worker.acquireConnection(&worker).?;
    try std.testing.expectEqual(@as(u32, 1), first.index);
    try std.testing.expectEqual(@as(u32, 0), second.index);
    try std.testing.expect(tcp_worker.acquireConnection(&worker) == null);
    tcp_worker.restoreConnection(&worker, first);
    try std.testing.expectEqual(first, tcp_worker.acquireConnection(&worker).?);
}

test "TCP worker rejects foreign completion request contexts" {
    var connections: [1]internal.Connection = .{. { .index = 0 }};
    var worker: internal.Worker = .{ .connections = &connections, .slot_count = 1 };
    connections[0].owner = &worker;
    connections[0].request.connection = &connections[0];
    try std.testing.expect(tcp_worker.completionContextValid(&worker, &connections[0].request));

    var foreign: internal.Connection = .{};
    foreign.owner = &worker;
    foreign.request.connection = &foreign;
    try std.testing.expect(!tcp_worker.completionContextValid(&worker, &foreign.request));
}

test "TCP worker completion progress closes on EOF and preserves partial sends" {
    var connection: internal.Connection = .{};
    try std.testing.expectEqual(tcp_worker.Progress.close, tcp_worker.applySuccessfulProgress(&connection, .receive, 0));
    try std.testing.expectEqual(tcp_worker.Progress.post_send, tcp_worker.applySuccessfulProgress(&connection, .receive, 11));
    try std.testing.expectEqual(@as(usize, 11), connection.echo_bytes);
    try std.testing.expectEqual(@as(usize, 0), connection.send_offset);
    try std.testing.expectEqual(tcp_worker.Progress.post_send, tcp_worker.applySuccessfulProgress(&connection, .send, 4));
    try std.testing.expectEqual(@as(usize, 4), connection.send_offset);
    try std.testing.expectEqual(tcp_worker.Progress.post_receive, tcp_worker.applySuccessfulProgress(&connection, .send, 7));
    try std.testing.expectEqual(@as(usize, 0), connection.send_offset);
}

test "TCP worker refreshes and expires idle deadlines exactly" {
    var connection: internal.Connection = .{};
    tcp_worker.refreshDeadline(&connection, 9000, 3);
    try std.testing.expectEqual(@as(u64, 12000), connection.deadline);
    try std.testing.expect(!tcp_worker.deadlineExpired(&connection, 11999));
    try std.testing.expect(tcp_worker.deadlineExpired(&connection, 12000));
}

test "TCP worker arms RIO notification before ready and drains control shutdown" {
    var winsock = try win32.Winsock.init();
    defer winsock.deinit();
    const api = try rio.Api.load();
    var options: server.types.Options = .{
        .protocol = .tcp,
        .worker_count = 1,
        .rio_buffer_bytes = 4096,
        .cq_capacity = 64,
        .memory_bytes = 1024 * 1024,
    };
    var failed = std.atomic.Value(bool).init(false);
    var worker: internal.Worker = .{};
    var resources: tcp_worker.WorkerResources = .{};
    try std.testing.expect(tcp_worker.initializeWorker(&worker, &api, &options, &failed, 0, 1, &resources));
    defer tcp_worker.destroyWorker(&worker);
    try std.testing.expect(tcp_worker.startWorker(&worker));
    try std.testing.expect(worker.ready);
    try std.testing.expect(worker.notification_armed);
    tcp_worker.postStop(&worker);
    tcp_worker.postAdmissionClosed(&worker);
    tcp_worker.joinWorker(&worker);
    try std.testing.expect(worker.stopping);
    try std.testing.expect(worker.admission_closed);
    try std.testing.expect(!worker.notification_armed);
    try std.testing.expectEqual(@as(u32, 0), worker.active_count);
    try std.testing.expect(!failed.load(.acquire));
}
