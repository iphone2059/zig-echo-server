const std = @import("std");
const contract = @import("ces_contract.zig");
const fault_guards = @import("fault_guards.zig");
const internal = @import("engine_internal.zig");
const rio = @import("rio.zig");
const timer_heap = @import("timer_heap.zig");
const types = @import("types.zig");
const win32 = @import("win32.zig");
const c = win32.c;

pub const stop_key: usize = 1;
pub const admission_closed_key: usize = 2;
const batch_size: u32 = 256;

pub const Progress = enum { close, post_receive, post_send };

pub const WorkerResources = internal.WorkerResources;
pub const WorkerInitError = error{
    Port, ReadyEvent, Capacity, Arena, Connections, FreeIndices, TimerNodes, TimerPositions,
    SocketOwners, TimerHeap, Registration, CompletionQueue,
};

fn resources(worker: *internal.Worker) *WorkerResources {
    return worker.resources.?;
}

pub fn connectionCapacity(options: *const types.Options, worker_count: u32) ?u32 {
    if (worker_count == 0 or options.rio_buffer_bytes == 0) return null;
    const memory_share = options.memory_bytes / worker_count;
    const possible_slots = memory_share / options.rio_buffer_bytes;
    if (possible_slots == 0) return null;
    const capacity = contract.tcpConnectionCapacity(options.cq_capacity, possible_slots);
    return if (capacity == 0) null else capacity;
}

pub fn acquireConnection(worker: *internal.Worker) ?*internal.Connection {
    if (worker.free_count == 0 or worker.connections == null or worker.free_indices == null) return null;
    worker.free_count -= 1;
    const index = worker.free_indices.?[worker.free_count];
    if (index >= worker.slot_count) win32.failFast("worker free index", c.ERROR_INVALID_DATA);
    return &worker.connections.?[index];
}

pub fn restoreConnection(worker: *internal.Worker, connection: *internal.Connection) void {
    if (worker.free_indices == null or connection.index >= worker.slot_count or worker.free_count >= worker.slot_count)
        win32.failFast("worker free stack restore", c.ERROR_INVALID_DATA);
    worker.free_indices.?[worker.free_count] = connection.index;
    worker.free_count += 1;
}

pub fn completionContextValid(worker: *const internal.Worker, request: *const internal.Request) bool {
    if (worker.connections == null or worker.slot_count == 0) return false;
    const connections = worker.connections.?[0..worker.slot_count];
    return internal.requestContextValid(request, connections) and request.connection.?.owner == worker;
}

pub fn applySuccessfulProgress(connection: *internal.Connection, operation: internal.EngineOperation, transferred: u32) Progress {
    if (operation == .receive) {
        if (transferred == 0) return .close;
        connection.echo_bytes = transferred;
        connection.send_offset = 0;
        return .post_send;
    }
    if (!contract.advanceOffset(connection.echo_bytes, transferred, &connection.send_offset)) return .close;
    if (connection.send_offset < connection.echo_bytes) return .post_send;
    connection.send_offset = 0;
    return .post_receive;
}

pub fn refreshDeadline(connection: *internal.Connection, now: u64, timeout_seconds: u32) void {
    connection.deadline = now +% @as(u64, timeout_seconds) * 1000;
}

pub fn deadlineExpired(connection: *const internal.Connection, now: u64) bool {
    return now >= connection.deadline;
}

fn arm(worker: *internal.Worker) void {
    if (worker.notification_armed) win32.failFast("duplicate worker RIONotify", c.ERROR_INVALID_STATE);
    worker.notification_overlapped = std.mem.zeroes(c.OVERLAPPED);
    const status = worker.rio_api.?.notify(worker.completion_queue);
    fault_guards.requireNotifySuccess(status, "RIONotify(worker)");
    fault_guards.requireTransition(contract.notificationMarkRearmed(&worker.notification_armed), "notification rearm transition");
}

fn closeSocket(connection: *internal.Connection) void {
    const worker = connection.owner.?;
    resources(worker).connection_sockets.?[connection.index].deinit();
    connection.socket = c.INVALID_SOCKET;
}

fn releaseConnection(connection: *internal.Connection) void {
    const worker = connection.owner.?;
    closeSocket(connection);
    connection.request_queue = c.RIO_INVALID_RQ;
    connection.active = false;
    connection.closing = false;
    connection.outstanding = 0;
    restoreConnection(worker, connection);
    if (worker.active_count == 0) win32.failFast("worker active count", c.ERROR_INVALID_DATA);
    worker.active_count -= 1;
}

pub fn closeConnection(connection: *internal.Connection) void {
    if (!connection.active or connection.closing) return;
    connection.closing = true;
    _ = connection.owner.?.timers.?.remove(connection.index);
    closeSocket(connection);
    if (connection.outstanding == 0) releaseConnection(connection);
}

fn postReceive(connection: *internal.Connection) bool {
    const worker = connection.owner.?;
    connection.request.operation = .receive;
    connection.buffer.Offset = connection.index * worker.stride;
    connection.buffer.Length = worker.stride;
    if (!worker.rio_api.?.receive(connection.request_queue, &connection.buffer, 0, @ptrCast(&connection.request))) {
        win32.report("RIOReceive", @intCast(c.WSAGetLastError()));
        return false;
    }
    connection.outstanding += 1;
    refreshDeadline(connection, c.GetTickCount64(), worker.options.?.timeout_seconds);
    if (!worker.timers.?.insertOrUpdate(connection.index, connection.deadline))
        win32.failFast("timer insert(receive)", c.ERROR_INVALID_DATA);
    return true;
}

fn postSend(connection: *internal.Connection) bool {
    const worker = connection.owner.?;
    connection.request.operation = .send;
    connection.buffer.Offset = connection.index * worker.stride + @as(u32, @intCast(connection.send_offset));
    connection.buffer.Length = @intCast(connection.echo_bytes - connection.send_offset);
    if (!worker.rio_api.?.send(connection.request_queue, &connection.buffer, 0, @ptrCast(&connection.request))) {
        win32.report("RIOSend", @intCast(c.WSAGetLastError()));
        return false;
    }
    connection.outstanding += 1;
    refreshDeadline(connection, c.GetTickCount64(), worker.options.?.timeout_seconds);
    if (!worker.timers.?.insertOrUpdate(connection.index, connection.deadline))
        win32.failFast("timer insert(send)", c.ERROR_INVALID_DATA);
    return true;
}

fn processResult(worker: *internal.Worker, result: c.RIORESULT) void {
    worker.statistics.completions += 1;
    const raw = result.RequestContext orelse win32.failFast("worker null RequestContext", c.ERROR_INVALID_DATA);
    const request: *internal.Request = @ptrCast(@alignCast(raw));
    if (!completionContextValid(worker, request)) win32.failFast("worker RIO RequestContext", c.ERROR_INVALID_DATA);
    const connection = request.connection.?;
    if (connection.outstanding == 0) win32.failFast("worker RIO outstanding count", c.ERROR_INVALID_DATA);
    connection.outstanding -= 1;
    if (connection.closing) {
        if (connection.outstanding == 0) releaseConnection(connection);
        return;
    }
    if (result.Status != c.ERROR_SUCCESS) {
        closeConnection(connection);
        return;
    }

    if (request.operation == .receive) worker.statistics.receives += 1 else {
        worker.statistics.sends += 1;
        worker.statistics.bytes += result.BytesTransferred;
    }
    switch (applySuccessfulProgress(connection, request.operation, result.BytesTransferred)) {
        .close => closeConnection(connection),
        .post_send => if (!postSend(connection)) closeConnection(connection),
        .post_receive => if (!postReceive(connection)) closeConnection(connection),
    }
}

fn drain(worker: *internal.Worker) void {
    var results: [batch_size]c.RIORESULT = undefined;
    while (true) {
        const count = fault_guards.requireDequeueCount(worker.rio_api.?.dequeue(worker.completion_queue, &results, batch_size), batch_size, "RIODequeueCompletion(worker)");
        if (count == 0) return;
        for (results[0..count]) |result| processResult(worker, result);
    }
}

fn acknowledgeAccept(operation: *internal.AcceptOperation) void {
    if (c.PostQueuedCompletionStatus(operation.accept_port, 0, @intFromPtr(operation), null) == c.FALSE)
        win32.failFast("PostQueuedCompletionStatus(accept ack)", c.GetLastError());
}

fn takeSocket(worker: *internal.Worker, operation: *internal.AcceptOperation) void {
    var accepted_owner = win32.Socket{ .value = operation.socket_owner.take() };
    operation.socket = c.INVALID_SOCKET;
    if (worker.stopping) {
        accepted_owner.deinit();
        acknowledgeAccept(operation);
        return;
    }
    const connection = acquireConnection(worker) orelse {
        accepted_owner.deinit();
        acknowledgeAccept(operation);
        return;
    };
    const accepted = accepted_owner.get();
    const connection_index = connection.index;
    connection.* = .{
        .owner = worker,
        .socket = accepted,
        .buffer = .{
            .BufferId = worker.registration,
            .Offset = connection_index * worker.stride,
            .Length = worker.stride,
        },
        .request = .{},
        .index = connection_index,
        .active = true,
    };
    connection.request.connection = connection;
    resources(worker).connection_sockets.?[connection.index].reset(accepted_owner.take());

    var peer: c.SOCKADDR_STORAGE = std.mem.zeroes(c.SOCKADDR_STORAGE);
    var peer_length: c_int = @sizeOf(c.SOCKADDR_STORAGE);
    if (c.getpeername(accepted, @ptrCast(&peer), &peer_length) != 0) {
        win32.report("getpeername(accepted RIO socket)", @intCast(c.WSAGetLastError()));
        connection.active = false;
        restoreConnection(worker, connection);
        closeSocket(connection);
        acknowledgeAccept(operation);
        return;
    }
    connection.request_queue = worker.rio_api.?.createRq(accepted, 1, 1, 1, 1, worker.completion_queue, worker.completion_queue, @ptrCast(connection));
    if (connection.request_queue == c.RIO_INVALID_RQ) {
        win32.report("RIOCreateRequestQueue(TCP)", @intCast(c.WSAGetLastError()));
        connection.active = false;
        restoreConnection(worker, connection);
        closeSocket(connection);
        acknowledgeAccept(operation);
        return;
    }
    worker.active_count += 1;
    worker.statistics.accepted += 1;
    if (!postReceive(connection)) closeConnection(connection);
    acknowledgeAccept(operation);
}

fn stopWorkerNow(worker: *internal.Worker) void {
    worker.stopping = true;
    for (worker.connections.?[0..worker.slot_count]) |*connection| {
        if (connection.active) closeConnection(connection);
    }
}

fn workerThread(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
    const worker: *internal.Worker = @ptrCast(@alignCast(parameter.?));
    arm(worker);
    worker.ready = true;
    if (c.SetEvent(worker.ready_event) == c.FALSE) win32.failFast("SetEvent(worker ready)", c.GetLastError());

    while (true) {
        var transferred: c.DWORD = 0;
        var key: c.ULONG_PTR = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        const wait = worker.timers.?.waitMilliseconds(c.GetTickCount64());
        const ok = c.GetQueuedCompletionStatus(worker.port, &transferred, &key, &overlapped, wait);
        const native_error = if (ok == c.FALSE) c.GetLastError() else c.ERROR_SUCCESS;
        if (overlapped == &worker.notification_overlapped) {
            if (ok == c.FALSE) win32.failFast("GetQueuedCompletionStatus(worker notification)", native_error);
            if (!internal.notificationPacketMatches(key, overlapped, @intFromPtr(worker), &worker.notification_overlapped))
                win32.failFast("worker RIO notification key", c.ERROR_INVALID_DATA);
            fault_guards.requireTransition(contract.notificationMarkDelivered(&worker.notification_armed), "notification delivery transition");
            drain(worker);
            arm(worker);
        } else if (overlapped == null and key == stop_key) {
            stopWorkerNow(worker);
        } else if (overlapped == null and key == admission_closed_key) {
            worker.admission_closed = true;
        } else if (overlapped == null and key > admission_closed_key) {
            const operation: *internal.AcceptOperation = @ptrFromInt(key);
            takeSocket(worker, operation);
        } else if (ok == c.FALSE and native_error != c.WAIT_TIMEOUT) {
            win32.report("GetQueuedCompletionStatus(worker)", native_error);
            worker.failed.?.store(true, .release);
            stopWorkerNow(worker);
        } else if (!(ok == c.FALSE and native_error == c.WAIT_TIMEOUT and overlapped == null)) {
            win32.failFast("unexpected worker IOCP packet", c.ERROR_INVALID_DATA);
        }

        const now = c.GetTickCount64();
        while (worker.timers.?.popExpired(now)) |index| {
            const connection = &worker.connections.?[index];
            if (connection.active and !connection.closing) closeConnection(connection);
        }
        if (worker.stopping and worker.admission_closed and worker.active_count == 0) break;
    }

    var outstanding: u32 = 0;
    for (worker.connections.?[0..worker.slot_count]) |connection| outstanding += connection.outstanding;
    rio.retireCompletionQueue(&resources(worker).completion_queue, outstanding, &worker.notification_armed);
    worker.completion_queue = c.RIO_INVALID_CQ;
    return if (worker.failed.?.load(.acquire)) 1 else 0;
}

pub fn initializeWorker(worker: *internal.Worker, api: *const rio.Api, options: *const types.Options, failed: *std.atomic.Value(bool), worker_index: u32, worker_count: u32, resource_storage: *WorkerResources) WorkerInitError!void {
    return initializeWorkerImpl(worker, api, options, failed, worker_index, worker_count, resource_storage, null);
}

pub fn initializeWorkerFaultForTest(worker: *internal.Worker, api: *const rio.Api, options: *const types.Options, failed: *std.atomic.Value(bool), worker_index: u32, worker_count: u32, resource_storage: *WorkerResources, comptime stage: WorkerInitError) WorkerInitError!void {
    if (!@import("builtin").is_test) @compileError("worker setup fault injection is test-only");
    return initializeWorkerImpl(worker, api, options, failed, worker_index, worker_count, resource_storage, stage);
}

fn faultAt(comptime selected: ?WorkerInitError, comptime stage: WorkerInitError) bool {
    return selected != null and selected.? == stage;
}

fn initializeWorkerImpl(worker: *internal.Worker, api: *const rio.Api, options: *const types.Options, failed: *std.atomic.Value(bool), worker_index: u32, worker_count: u32, resource_storage: *WorkerResources, comptime fault_stage: ?WorkerInitError) WorkerInitError!void {
    worker.* = .{};
    resource_storage.* = .{};
    worker.resources = resource_storage;
    errdefer destroyWorker(worker);
    worker.rio_api = api;
    worker.options = options;
    worker.failed = failed;
    worker.worker_index = worker_index;
    worker.stride = options.rio_buffer_bytes;

    resource_storage.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    worker.port = resource_storage.port.get();
    if (worker.port == null) {
        win32.report("CreateIoCompletionPort(worker)", c.GetLastError());
        return error.Port;
    }
    if (faultAt(fault_stage, error.Port)) return error.Port;
    resource_storage.ready_event.reset(c.CreateEventW(null, c.TRUE, c.FALSE, null));
    worker.ready_event = resource_storage.ready_event.get();
    if (worker.ready_event == null) {
        win32.report("CreateEvent(worker)", c.GetLastError());
        return error.ReadyEvent;
    }
    if (faultAt(fault_stage, error.ReadyEvent)) return error.ReadyEvent;

    worker.slot_count = connectionCapacity(options, worker_count) orelse {
        win32.report("worker registered arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Capacity;
    };
    if (faultAt(fault_stage, error.Capacity)) return error.Capacity;
    const memory_share = options.memory_bytes / worker_count;
    const arena_bytes = contract.checkedArenaBytes(worker.slot_count, worker.stride, memory_share) orelse {
        win32.report("worker registered arena size", c.ERROR_ARITHMETIC_OVERFLOW);
        return error.Arena;
    };
    if (arena_bytes > std.math.maxInt(u32)) {
        win32.report("worker registered arena > DWORD", c.ERROR_ARITHMETIC_OVERFLOW);
        return error.Arena;
    }

    resource_storage.arena = win32.VirtualMemory.alloc(arena_bytes) catch {
        win32.report("VirtualAlloc(worker)", c.GetLastError());
        return error.Arena;
    };
    if (faultAt(fault_stage, error.Arena)) return error.Arena;
    worker.memory = resource_storage.arena.bytes();
    const allocator = std.heap.page_allocator;
    resource_storage.connections = allocator.alloc(internal.Connection, worker.slot_count) catch {
        win32.report("allocate worker connections", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.Connections;
    };
    if (faultAt(fault_stage, error.Connections)) return error.Connections;
    resource_storage.free_indices = allocator.alloc(u32, worker.slot_count) catch {
        win32.report("allocate worker free indices", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.FreeIndices;
    };
    if (faultAt(fault_stage, error.FreeIndices)) return error.FreeIndices;
    resource_storage.timer_nodes = allocator.alloc(timer_heap.Node, worker.slot_count) catch {
        win32.report("allocate worker timer nodes", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.TimerNodes;
    };
    if (faultAt(fault_stage, error.TimerNodes)) return error.TimerNodes;
    resource_storage.timer_positions = allocator.alloc(u32, worker.slot_count) catch {
        win32.report("allocate worker timer positions", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.TimerPositions;
    };
    if (faultAt(fault_stage, error.TimerPositions)) return error.TimerPositions;
    resource_storage.connection_sockets = allocator.alloc(win32.Socket, worker.slot_count) catch {
        win32.report("allocate worker socket owners", c.ERROR_NOT_ENOUGH_MEMORY);
        return error.SocketOwners;
    };
    for (resource_storage.connection_sockets.?) |*socket| socket.* = .{};
    if (faultAt(fault_stage, error.SocketOwners)) return error.SocketOwners;
    worker.connections = resource_storage.connections.?.ptr;
    worker.free_indices = resource_storage.free_indices.?.ptr;
    worker.timer_nodes = resource_storage.timer_nodes.?.ptr;
    worker.timer_positions = resource_storage.timer_positions.?.ptr;
    worker.timers = timer_heap.Heap.init(resource_storage.timer_nodes.?, resource_storage.timer_positions.?) catch {
        win32.report("initialize worker timers", c.ERROR_INVALID_DATA);
        return error.TimerHeap;
    };
    if (faultAt(fault_stage, error.TimerHeap)) return error.TimerHeap;
    for (resource_storage.connections.?, 0..) |*connection, index| {
        connection.* = .{ .index = @intCast(index) };
        resource_storage.free_indices.?[index] = worker.slot_count - @as(u32, @intCast(index)) - 1;
    }
    worker.free_count = worker.slot_count;

    resource_storage.registration.reset(api, api.registerBuffer(worker.memory.?, @intCast(arena_bytes)));
    worker.registration = resource_storage.registration.id;
    if (worker.registration == c.RIO_INVALID_BUFFERID) {
        win32.report("RIORegisterBuffer(worker)", @intCast(c.WSAGetLastError()));
        return error.Registration;
    }
    if (faultAt(fault_stage, error.Registration)) return error.Registration;
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = worker.port;
    notification.Iocp.CompletionKey = @ptrCast(worker);
    notification.Iocp.Overlapped = &worker.notification_overlapped;
    resource_storage.completion_queue.reset(api, api.createCq(worker.slot_count * 2, &notification));
    worker.completion_queue = resource_storage.completion_queue.value;
    if (worker.completion_queue == c.RIO_INVALID_CQ) {
        win32.report("RIOCreateCompletionQueue(worker)", @intCast(c.WSAGetLastError()));
        return error.CompletionQueue;
    }
    if (faultAt(fault_stage, error.CompletionQueue)) return error.CompletionQueue;
}

pub fn startWorker(worker: *internal.Worker) bool {
    const owned = resources(worker);
    owned.thread.reset(c.CreateThread(null, 0, workerThread, worker, 0, null));
    worker.thread = owned.thread.get();
    if (worker.thread == null) {
        win32.report("CreateThread(worker)", c.GetLastError());
        return false;
    }
    if (c.WaitForSingleObject(worker.ready_event, c.INFINITE) != c.WAIT_OBJECT_0 or !worker.ready) {
        win32.report("worker startup readiness", c.ERROR_INVALID_STATE);
        return false;
    }
    return true;
}

pub fn postHandoff(worker: *internal.Worker, operation: *internal.AcceptOperation) void {
    if (c.PostQueuedCompletionStatus(worker.port, 0, @intFromPtr(operation), null) == c.FALSE)
        win32.failFast("PostQueuedCompletionStatus(accept handoff)", c.GetLastError());
}

pub fn postAdmissionClosed(worker: *internal.Worker) void {
    if (c.PostQueuedCompletionStatus(worker.port, 0, admission_closed_key, null) == c.FALSE)
        win32.failFast("PostQueuedCompletionStatus(admission closed)", c.GetLastError());
}

pub fn postStop(worker: *internal.Worker) void {
    const ok = c.PostQueuedCompletionStatus(worker.port, 0, stop_key, null);
    fault_guards.requireControlPost(ok, if (ok == c.FALSE) c.GetLastError() else 0, "PostQueuedCompletionStatus(worker stop)");
}

pub fn joinWorker(worker: *internal.Worker) void {
    if (worker.thread != null) {
        if (c.WaitForSingleObject(worker.thread, c.INFINITE) != c.WAIT_OBJECT_0)
            win32.failFast("WaitForSingleObject(worker)", c.GetLastError());
    }
}

pub fn destroyWorker(worker: *internal.Worker) void {
    const owned = resources(worker);
    if (worker.thread != null) joinWorker(worker);
    owned.thread.deinit();
    worker.thread = null;
    if (!internal.workerStorageMayRelease(worker))
        win32.failFast("worker release precondition", c.ERROR_INVALID_STATE);

    if (worker.ready and worker.options != null and worker.options.?.stats) {
        var buffer: [512]u8 = undefined;
        const output = std.fmt.bufPrint(&buffer, "[worker {d}] accepted={d} completions={d} receives={d} sends={d} bytes={d} active={d}\n", .{
            worker.worker_index,     worker.statistics.accepted, worker.statistics.completions, worker.statistics.receives,
            worker.statistics.sends, worker.statistics.bytes,    worker.active_count,
        }) catch win32.failFast("format worker statistics", c.ERROR_INSUFFICIENT_BUFFER);
        if (!win32.writeStdout(output)) win32.failFast("write worker statistics", c.GetLastError());
    }

    if (owned.connection_sockets) |sockets| {
        for (sockets) |*socket| socket.deinit();
    }
    owned.completion_queue.deinit();
    owned.registration.deinit();
    owned.arena.deinit();
    const allocator = std.heap.page_allocator;
    if (owned.connection_sockets) |slice| allocator.free(slice);
    if (owned.connections) |slice| allocator.free(slice);
    if (owned.free_indices) |slice| allocator.free(slice);
    if (owned.timer_nodes) |slice| allocator.free(slice);
    if (owned.timer_positions) |slice| allocator.free(slice);
    owned.connection_sockets = null;
    owned.connections = null;
    owned.free_indices = null;
    owned.timer_nodes = null;
    owned.timer_positions = null;
    owned.ready_event.deinit();
    owned.port.deinit();
    worker.resources = null;
    worker.connections = null;
    worker.free_indices = null;
    worker.timer_nodes = null;
    worker.timer_positions = null;
    worker.timers = null;
    worker.memory = null;
    worker.ready_event = null;
    worker.port = null;
}

