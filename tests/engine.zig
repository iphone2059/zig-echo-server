const std = @import("std");
const server = @import("server");
const win32 = server.win32;
const rio = server.rio;
const c = win32.c;
const timer_heap = server.timer_heap;
const internal = server.engine_internal;
const tcp_worker = server.tcp_worker;
const tcp_acceptor = server.tcp_acceptor;
const coordinator = server.engine;

test "server worker and acceptor own typed resources" {
    comptime {
        if (@TypeOf((@as(internal.Worker, .{})).resources) != ?*internal.WorkerResources)
            @compileError("worker resources must be a typed owner pointer");
        if (@TypeOf((@as(internal.Acceptor, .{})).resources) != ?*internal.AcceptorResources)
            @compileError("acceptor resources must be a typed owner pointer");
        if (tcp_worker.WorkerResources != internal.WorkerResources)
            @compileError("worker resource alias changed");
        if (tcp_acceptor.AcceptorResources != internal.AcceptorResources)
            @compileError("acceptor resource alias changed");
    }
}

test "unpublished partially acquired server owners release only their resources" {
    var worker_resources: internal.WorkerResources = .{};
    worker_resources.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    worker_resources.ready_event.reset(c.CreateEventW(null, c.TRUE, c.FALSE, null));
    try std.testing.expect(worker_resources.port.get() != null);
    try std.testing.expect(worker_resources.ready_event.get() != null);
    var worker: internal.Worker = .{
        .resources = &worker_resources,
        .port = worker_resources.port.get(),
        .ready_event = worker_resources.ready_event.get(),
    };
    tcp_worker.destroyWorker(&worker);
    try std.testing.expect(worker.resources == null);
    try std.testing.expect(worker_resources.port.get() == null);
    try std.testing.expect(worker_resources.ready_event.get() == null);

    var acceptor_resources: internal.AcceptorResources = .{};
    acceptor_resources.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    acceptor_resources.ready_event.reset(c.CreateEventW(null, c.TRUE, c.FALSE, null));
    try std.testing.expect(acceptor_resources.port.get() != null);
    try std.testing.expect(acceptor_resources.ready_event.get() != null);
    var acceptor: internal.Acceptor = .{
        .resources = &acceptor_resources,
        .port = acceptor_resources.port.get(),
        .ready_event = acceptor_resources.ready_event.get(),
    };
    tcp_acceptor.destroyAcceptor(&acceptor);
    try std.testing.expect(acceptor.resources == null);
    try std.testing.expect(acceptor_resources.port.get() == null);
    try std.testing.expect(acceptor_resources.ready_event.get() == null);
}

test "published worker storage waits for notification and every request" {
    var nodes: [1]timer_heap.Node = undefined;
    var positions: [1]u32 = undefined;
    var heap = try timer_heap.Heap.init(&nodes, &positions);
    var connections: [1]internal.Connection = .{.{}};
    var worker: internal.Worker = .{
        .ready = true,
        .admission_closed = true,
        .connections = &connections,
        .slot_count = 1,
        .timers = heap,
    };
    try std.testing.expect(internal.workerStorageMayRelease(&worker));
    worker.notification_armed = true;
    try std.testing.expect(!internal.workerStorageMayRelease(&worker));
    worker.notification_armed = false;
    connections[0].outstanding = 1;
    try std.testing.expect(!internal.workerStorageMayRelease(&worker));
    connections[0].outstanding = 0;
    connections[0].active = true;
    try std.testing.expect(!internal.workerStorageMayRelease(&worker));
    connections[0].active = false;
    worker.active_count = 1;
    try std.testing.expect(!internal.workerStorageMayRelease(&worker));
    worker.active_count = 0;
    worker.admission_closed = false;
    try std.testing.expect(!internal.workerStorageMayRelease(&worker));
    worker.admission_closed = true;
    try std.testing.expect(heap.insertOrUpdate(0, 10));
    worker.timers = heap;
    try std.testing.expect(!internal.workerStorageMayRelease(&worker));
}

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

test "server closes idle CQ with an armed and already queued notification" {
    var winsock = try win32.Winsock.init();
    defer winsock.deinit();
    const api = try rio.Api.load();
    var port = win32.Handle{ .value = c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1) };
    defer port.deinit();
    try std.testing.expect(port.value != null);
    var notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = port.value;
    notification.Iocp.CompletionKey = @ptrCast(&notification_overlapped);
    notification.Iocp.Overlapped = &notification_overlapped;
    var cq = rio.CompletionQueue{ .api = &api, .value = api.createCq(8, &notification) };
    defer cq.deinit();
    try std.testing.expect(cq.value != c.RIO_INVALID_CQ);
    try std.testing.expectEqual(@as(c_int, c.ERROR_SUCCESS), api.notify(cq.value));
    var armed = true;
    try std.testing.expect(c.PostQueuedCompletionStatus(port.value, 0, @intFromPtr(&notification_overlapped), &notification_overlapped) != c.FALSE);

    rio.retireCompletionQueue(&cq, 0, &armed);

    try std.testing.expectEqual(c.RIO_INVALID_CQ, cq.value);
    try std.testing.expect(!armed);
    var transferred: c.DWORD = 0;
    var key: c.ULONG_PTR = 0;
    var overlapped: [*c]c.OVERLAPPED = null;
    try std.testing.expect(c.GetQueuedCompletionStatus(port.value, &transferred, &key, &overlapped, 0) != c.FALSE);
    try std.testing.expectEqual(@intFromPtr(&notification_overlapped), key);
    try std.testing.expect(overlapped == &notification_overlapped);
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
    var connections: [1]internal.Connection = .{.{ .index = 0 }};
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

test "AcceptEx operation permits only the exact ownership cycle" {
    var operation: internal.AcceptOperation = .{};
    try std.testing.expect(tcp_acceptor.transitionState(&operation, .idle, .posted));
    try std.testing.expect(!tcp_acceptor.transitionState(&operation, .idle, .posted));
    try std.testing.expect(tcp_acceptor.transitionState(&operation, .posted, .transit));
    try std.testing.expect(!tcp_acceptor.transitionState(&operation, .posted, .idle));
    try std.testing.expect(tcp_acceptor.transitionState(&operation, .transit, .idle));
}

test "AcceptEx completion identity requires a published owned operation" {
    var acceptor: internal.Acceptor = .{};
    var operations: [2]internal.AcceptOperation = .{ .{}, .{} };
    acceptor.operations = &operations;
    acceptor.operation_count = operations.len;
    operations[0].owner = &acceptor;
    operations[0].state = .posted;
    try std.testing.expect(tcp_acceptor.completionIdentityValid(&acceptor, &operations[0].overlapped));
    try std.testing.expect(!tcp_acceptor.completionIdentityValid(&acceptor, &operations[1].overlapped));
    operations[0].state = .transit;
    try std.testing.expect(!tcp_acceptor.completionIdentityValid(&acceptor, &operations[0].overlapped));
}

test "AcceptEx readiness requires a listening socket and every accept posted" {
    try std.testing.expect(!tcp_acceptor.canPublishReady(c.INVALID_SOCKET, 32, 32));
    try std.testing.expect(!tcp_acceptor.canPublishReady(9, 31, 32));
    try std.testing.expect(tcp_acceptor.canPublishReady(9, 32, 32));
}

test "AcceptEx shutdown closes posted sockets but waits for transit acknowledgements" {
    try std.testing.expectEqual(tcp_acceptor.ShutdownAction.none, tcp_acceptor.shutdownAction(.idle));
    try std.testing.expectEqual(tcp_acceptor.ShutdownAction.close_posted, tcp_acceptor.shutdownAction(.posted));
    try std.testing.expectEqual(tcp_acceptor.ShutdownAction.wait_ack, tcp_acceptor.shutdownAction(.transit));
}

test "AcceptEx pool count is exactly 32 per worker capped at 1024" {
    try std.testing.expectEqual(@as(?u32, 32), tcp_acceptor.operationCount(1));
    try std.testing.expectEqual(@as(?u32, 256), tcp_acceptor.operationCount(8));
    try std.testing.expectEqual(@as(?u32, 1024), tcp_acceptor.operationCount(64));
    try std.testing.expectEqual(@as(?u32, null), tcp_acceptor.operationCount(0));
}

test "TCP coordinator resolves automatic worker count to the C++ 1 through 32 contract" {
    try std.testing.expectEqual(@as(u32, 1), coordinator.resolveWorkerCount(0, 0));
    try std.testing.expectEqual(@as(u32, 1), coordinator.resolveWorkerCount(0, 1));
    try std.testing.expectEqual(@as(u32, 12), coordinator.resolveWorkerCount(0, 12));
    try std.testing.expectEqual(@as(u32, 32), coordinator.resolveWorkerCount(0, 128));
    try std.testing.expectEqual(@as(u32, 7), coordinator.resolveWorkerCount(7, 128));
}

test "TCP coordinator admits only acceptor-first shutdown ordering" {
    var sequence: coordinator.ShutdownSequence = .{};
    try std.testing.expect(!sequence.advance(.admission_closed));
    try std.testing.expect(sequence.advance(.acceptor_stopped));
    try std.testing.expect(sequence.advance(.admission_closed));
    try std.testing.expect(!sequence.advance(.joined));
    try std.testing.expect(sequence.advance(.workers_stopped));
    try std.testing.expect(sequence.advance(.joined));
    try std.testing.expectEqual(coordinator.ShutdownPhase.joined, sequence.phase);
}

test "TCP coordinator formats exact aggregate statistics on stdout" {
    var buffer: [512]u8 = undefined;
    const output = try coordinator.formatTcpStatistics(&buffer, &.{
        .accepted = 4,
        .completions = 9,
        .receives = 5,
        .sends = 4,
        .bytes = 1048576,
    }, 2000, 0);
    try std.testing.expectEqualStrings("final protocol=tcp elapsed_ms=2000 accepted=4 completions=9 receives=5 sends=4 bytes=1048576 MiB_per_sec=0.50 active=0\n", output);
}
