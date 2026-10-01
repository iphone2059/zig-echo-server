const std = @import("std");
const internal = @import("engine_internal.zig");
const rio = @import("rio.zig");
const tcp_worker = @import("tcp_worker.zig");
const types = @import("types.zig");
const win32 = @import("win32.zig");
const c = win32.c;

const accepts_per_worker: u32 = 32;
const max_accepts: u32 = 1024;

pub const ShutdownAction = enum { none, close_posted, wait_ack };

pub const AcceptorResources = internal.AcceptorResources;

fn resources(acceptor: *internal.Acceptor) *AcceptorResources {
    return acceptor.resources.?;
}

pub fn operationCount(worker_count: u32) ?u32 {
    if (worker_count == 0) return null;
    const product = @mulWithOverflow(worker_count, accepts_per_worker);
    if (product[1] != 0) return max_accepts;
    return @min(product[0], max_accepts);
}

pub fn transitionState(operation: *internal.AcceptOperation, expected: internal.AcceptState, desired: internal.AcceptState) bool {
    if (operation.state != expected) return false;
    const legal = (expected == .idle and desired == .posted) or
        (expected == .posted and (desired == .transit or desired == .idle)) or
        (expected == .transit and desired == .idle);
    if (!legal) return false;
    operation.state = desired;
    return true;
}

pub fn completionIdentityValid(acceptor: *const internal.Acceptor, overlapped: *const c.OVERLAPPED) bool {
    if (acceptor.operations == null or acceptor.operation_count == 0) return false;
    const operation: *const internal.AcceptOperation = @fieldParentPtr("overlapped", overlapped);
    return operation.state == .posted and
        internal.acceptContextValid(operation, acceptor.operations.?[0..acceptor.operation_count], acceptor);
}

pub fn canPublishReady(listener: c.SOCKET, posted: u32, total: u32) bool {
    return listener != c.INVALID_SOCKET and total != 0 and posted == total;
}

pub fn shutdownAction(state: internal.AcceptState) ShutdownAction {
    return switch (state) {
        .idle => .none,
        .posted => .close_posted,
        .transit => .wait_ack,
    };
}

fn hasLive(acceptor: *const internal.Acceptor) bool {
    for (acceptor.operations.?[0..acceptor.operation_count]) |operation| {
        if (operation.state != .idle) return true;
    }
    return false;
}

fn closeListener(acceptor: *internal.Acceptor) void {
    resources(acceptor).listener.deinit();
    acceptor.listener = c.INVALID_SOCKET;
}

fn closeAccept(operation: *internal.AcceptOperation) void {
    operation.socket_owner.deinit();
    operation.socket = c.INVALID_SOCKET;
}

fn loadExtension(comptime T: type, socket: c.SOCKET, identifier_value: c.GUID, stage: []const u8) ?T {
    var identifier = identifier_value;
    var function: ?T = null;
    var bytes: c.DWORD = 0;
    if (c.WSAIoctl(socket, c.SIO_GET_EXTENSION_FUNCTION_POINTER, &identifier, @sizeOf(c.GUID), @ptrCast(&function), @sizeOf(?T), &bytes, null, null) != 0) {
        win32.report(stage, @intCast(c.WSAGetLastError()));
        return null;
    }
    return function;
}

pub fn postAccept(operation: *internal.AcceptOperation) bool {
    const acceptor = operation.owner.?;
    operation.overlapped = std.mem.zeroes(c.OVERLAPPED);
    operation.socket_owner.reset(win32.registeredSocket(c.SOCK_STREAM, c.IPPROTO_TCP));
    operation.socket = operation.socket_owner.get();
    if (operation.socket == c.INVALID_SOCKET) {
        win32.report("WSASocketW(accepted RIO socket)", @intCast(c.WSAGetLastError()));
        return false;
    }
    if (!transitionState(operation, .idle, .posted)) win32.failFast("accept post state", c.ERROR_INVALID_STATE);
    var received: c.DWORD = 0;
    const accepted = acceptor.accept_ex.?(acceptor.listener, operation.socket, &operation.addresses, 0,
        @sizeOf(c.SOCKADDR_STORAGE) + 16, @sizeOf(c.SOCKADDR_STORAGE) + 16, &received, &operation.overlapped);
    if (accepted == c.FALSE and c.WSAGetLastError() != c.ERROR_IO_PENDING) {
        win32.report("AcceptEx", @intCast(c.WSAGetLastError()));
        if (!transitionState(operation, .posted, .idle)) win32.failFast("accept rollback state", c.ERROR_INVALID_STATE);
        closeAccept(operation);
        return false;
    }
    return true;
}

fn beginStop(acceptor: *internal.Acceptor) void {
    if (acceptor.stopping) return;
    acceptor.stopping = true;
    closeListener(acceptor);
    for (acceptor.operations.?[0..acceptor.operation_count]) |*operation| {
        if (shutdownAction(operation.state) == .close_posted) closeAccept(operation);
    }
}

fn failAndStop(acceptor: *internal.Acceptor, stage: []const u8, native_error: u32) void {
    win32.report(stage, native_error);
    acceptor.failed.?.store(true, .release);
    beginStop(acceptor);
}

fn completeAccept(acceptor: *internal.Acceptor, operation: *internal.AcceptOperation, wait_error: u32) void {
    var accept_bytes: c.DWORD = 0;
    var flags: c.DWORD = 0;
    var completion_error = wait_error;
    const completed = c.WSAGetOverlappedResult(acceptor.listener, &operation.overlapped, &accept_bytes, c.FALSE, &flags);
    if (completed == c.FALSE) completion_error = @intCast(c.WSAGetLastError());
    if (completed == c.FALSE) {
        if (!transitionState(operation, .posted, .idle)) win32.failFast("accept completion state", c.ERROR_INVALID_STATE);
        closeAccept(operation);
        if (!acceptor.stopping) failAndStop(acceptor, "AcceptEx completion", completion_error);
        return;
    }

    const listener_value = acceptor.listener;
    if (c.setsockopt(operation.socket, c.SOL_SOCKET, c.SO_UPDATE_ACCEPT_CONTEXT, @ptrCast(&listener_value), @sizeOf(c.SOCKET)) != 0 or
        !win32.configureSocket(operation.socket, acceptor.options.?.socket_buffer_bytes, true))
    {
        if (!transitionState(operation, .posted, .idle)) win32.failFast("accept configure state", c.ERROR_INVALID_STATE);
        closeAccept(operation);
        failAndStop(acceptor, "accepted socket configuration", @intCast(c.WSAGetLastError()));
        return;
    }
    var local: ?*c.SOCKADDR = null;
    var remote: ?*c.SOCKADDR = null;
    var local_length: c_int = 0;
    var remote_length: c_int = 0;
    acceptor.get_accept_addresses.?(&operation.addresses, 0, @sizeOf(c.SOCKADDR_STORAGE) + 16,
        @sizeOf(c.SOCKADDR_STORAGE) + 16, &local, &local_length, &remote, &remote_length);
    if (local == null or remote == null or local_length <= 0 or remote_length <= 0) {
        if (!transitionState(operation, .posted, .idle)) win32.failFast("accept address state", c.ERROR_INVALID_STATE);
        closeAccept(operation);
        failAndStop(acceptor, "GetAcceptExSockaddrs", c.WSAEINVAL);
        return;
    }
    if (!transitionState(operation, .posted, .transit)) win32.failFast("accept transit state", c.ERROR_INVALID_STATE);
    const worker = &acceptor.workers.?[acceptor.next_worker % acceptor.worker_count];
    acceptor.next_worker +%= 1;
    tcp_worker.postHandoff(worker, operation);
}

fn publishReady(acceptor: *internal.Acceptor, posted: u32) void {
    acceptor.startup_ok = canPublishReady(acceptor.listener, posted, acceptor.operation_count);
    acceptor.ready = true;
    if (c.SetEvent(acceptor.ready_event) == c.FALSE) win32.failFast("SetEvent(acceptor ready)", c.GetLastError());
}

fn acceptorThread(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
    const acceptor: *internal.Acceptor = @ptrCast(@alignCast(parameter.?));
    var posted: u32 = 0;
    for (acceptor.operations.?[0..acceptor.operation_count]) |*operation| {
        if (!postAccept(operation)) {
            acceptor.failed.?.store(true, .release);
            beginStop(acceptor);
            break;
        }
        posted += 1;
    }
    publishReady(acceptor, posted);

    while (!acceptor.stopping or hasLive(acceptor)) {
        var transferred: c.DWORD = 0;
        var key: c.ULONG_PTR = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        const ok = c.GetQueuedCompletionStatus(acceptor.port, &transferred, &key, &overlapped, 100);
        const wait_error = if (ok == c.FALSE) c.GetLastError() else c.ERROR_SUCCESS;
        if (overlapped == null and key == tcp_worker.stop_key) {
            beginStop(acceptor);
            continue;
        }
        if (overlapped == null and key > tcp_worker.stop_key) {
            const operation: *internal.AcceptOperation = @ptrFromInt(key);
            if (!internal.acceptContextValid(operation, acceptor.operations.?[0..acceptor.operation_count], acceptor) or operation.state != .transit)
                win32.failFast("accept acknowledgement identity", c.ERROR_INVALID_DATA);
            if (!transitionState(operation, .transit, .idle)) win32.failFast("accept acknowledgement state", c.ERROR_INVALID_STATE);
            if (!acceptor.stopping and !postAccept(operation)) failAndStop(acceptor, "repost AcceptEx", @intCast(c.WSAGetLastError()));
            continue;
        }
        if (overlapped != null) {
            if (!completionIdentityValid(acceptor, overlapped)) win32.failFast("AcceptEx completion identity", c.ERROR_INVALID_DATA);
            const operation: *internal.AcceptOperation = @fieldParentPtr("overlapped", @as(*c.OVERLAPPED, @ptrCast(overlapped)));
            if (ok == c.FALSE and acceptor.stopping) {
                if (!transitionState(operation, .posted, .idle)) win32.failFast("cancelled accept state", c.ERROR_INVALID_STATE);
                closeAccept(operation);
            } else {
                completeAccept(acceptor, operation, wait_error);
            }
            continue;
        }
        if (ok == c.FALSE and wait_error != c.WAIT_TIMEOUT) {
            failAndStop(acceptor, "GetQueuedCompletionStatus(acceptor)", wait_error);
        } else if (!(ok == c.FALSE and wait_error == c.WAIT_TIMEOUT and overlapped == null)) {
            win32.failFast("unexpected acceptor IOCP packet", c.ERROR_INVALID_DATA);
        }
    }
    for (acceptor.workers.?[0..acceptor.worker_count]) |*worker| tcp_worker.postAdmissionClosed(worker);
    return if (acceptor.failed.?.load(.acquire)) 1 else 0;
}

pub fn initializeAcceptor(acceptor: *internal.Acceptor, api: *const rio.Api, options: *const types.Options, workers: []internal.Worker, failed: *std.atomic.Value(bool), resource_storage: *AcceptorResources) bool {
    acceptor.* = .{};
    resource_storage.* = .{};
    if (workers.len == 0 or workers.len > std.math.maxInt(u32)) return false;
    acceptor.resources = resource_storage;
    acceptor.rio_api = api;
    acceptor.options = options;
    acceptor.workers = workers.ptr;
    acceptor.worker_count = @intCast(workers.len);
    acceptor.failed = failed;
    acceptor.operation_count = operationCount(acceptor.worker_count).?;

    resource_storage.listener.reset(win32.registeredSocket(c.SOCK_STREAM, c.IPPROTO_TCP));
    acceptor.listener = resource_storage.listener.get();
    resource_storage.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
    acceptor.port = resource_storage.port.get();
    resource_storage.ready_event.reset(c.CreateEventW(null, c.TRUE, c.FALSE, null));
    acceptor.ready_event = resource_storage.ready_event.get();
    if (acceptor.listener == c.INVALID_SOCKET or acceptor.port == null or acceptor.ready_event == null) {
        win32.report("TCP listener/IOCP/event creation", @intCast(c.WSAGetLastError()));
        return false;
    }
    if (!win32.configureSocket(acceptor.listener, options.socket_buffer_bytes, true)) return false;
    var address: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
    address.sin_family = c.AF_INET;
    address.sin_addr.S_un.S_addr = c.htonl(c.INADDR_ANY);
    address.sin_port = c.htons(options.port);
    if (c.bind(acceptor.listener, @ptrCast(&address), @sizeOf(c.SOCKADDR_IN)) != 0 or c.listen(acceptor.listener, c.SOMAXCONN) != 0) {
        win32.report("bind/listen(TCP)", @intCast(c.WSAGetLastError()));
        return false;
    }
    if (c.CreateIoCompletionPort(@ptrFromInt(acceptor.listener), acceptor.port, 0, 1) != acceptor.port) {
        win32.report("associate listener IOCP", c.GetLastError());
        return false;
    }
    acceptor.accept_ex = loadExtension(c.LPFN_ACCEPTEX, acceptor.listener, c.WSAID_ACCEPTEX, "load AcceptEx") orelse return false;
    acceptor.get_accept_addresses = loadExtension(c.LPFN_GETACCEPTEXSOCKADDRS, acceptor.listener, c.WSAID_GETACCEPTEXSOCKADDRS, "load GetAcceptExSockaddrs") orelse return false;

    resource_storage.operations = std.heap.page_allocator.alloc(internal.AcceptOperation, acceptor.operation_count) catch {
        win32.report("allocate accept operations", c.ERROR_NOT_ENOUGH_MEMORY);
        return false;
    };
    acceptor.operations = resource_storage.operations.?.ptr;
    for (resource_storage.operations.?, 0..) |*operation, index| {
        operation.* = .{
            .owner = acceptor,
            .accept_port = acceptor.port,
            .index = @intCast(index),
        };
    }
    return true;
}

pub fn startAcceptor(acceptor: *internal.Acceptor) bool {
    const owned = resources(acceptor);
    owned.thread.reset(c.CreateThread(null, 0, acceptorThread, acceptor, 0, null));
    acceptor.thread = owned.thread.get();
    if (acceptor.thread == null) {
        win32.report("CreateThread(acceptor)", c.GetLastError());
        return false;
    }
    if (c.WaitForSingleObject(acceptor.ready_event, c.INFINITE) != c.WAIT_OBJECT_0 or !acceptor.ready or !acceptor.startup_ok) {
        win32.report("acceptor startup readiness", c.ERROR_INVALID_STATE);
        return false;
    }
    return true;
}

pub fn stopAcceptor(acceptor: *internal.Acceptor) void {
    if (c.PostQueuedCompletionStatus(acceptor.port, 0, tcp_worker.stop_key, null) == c.FALSE)
        win32.failFast("PostQueuedCompletionStatus(acceptor stop)", c.GetLastError());
}

pub fn joinAcceptor(acceptor: *internal.Acceptor) void {
    if (acceptor.thread != null and c.WaitForSingleObject(acceptor.thread, c.INFINITE) != c.WAIT_OBJECT_0)
        win32.failFast("WaitForSingleObject(acceptor)", c.GetLastError());
}

pub fn destroyAcceptor(acceptor: *internal.Acceptor) void {
    const owned = resources(acceptor);
    if (acceptor.thread != null) joinAcceptor(acceptor);
    owned.thread.deinit();
    acceptor.thread = null;
    if (acceptor.ready and hasLive(acceptor)) win32.failFast("acceptor release precondition", c.ERROR_INVALID_STATE);
    if (owned.operations) |operations| {
        for (operations) |*operation| closeAccept(operation);
        std.heap.page_allocator.free(operations);
    }
    owned.operations = null;
    closeListener(acceptor);
    owned.ready_event.deinit();
    owned.port.deinit();
    acceptor.operations = null;
    acceptor.ready_event = null;
    acceptor.port = null;
    acceptor.resources = null;
}
