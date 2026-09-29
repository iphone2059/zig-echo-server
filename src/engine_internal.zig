const std = @import("std");
const types = @import("types.zig");
const win32 = @import("win32.zig");
const rio = @import("rio.zig");
const timer_heap = @import("timer_heap.zig");
const c = win32.c;

pub const WorkerPhase = enum(u8) {
    starting = 0,
    running = 1,
    quiescing = 2,
    admission_closed = 3,
    draining = 4,
    stopped = 5,
};

pub const UdpPhase = enum(u8) { running = 0, draining = 1, stopped = 2 };
pub const EngineOperation = enum(u8) { receive, send };
pub const AcceptState = enum(i32) { idle = 0, posted = 1, transit = 2 };

pub const WorkerLifecycle = struct {
    phase: WorkerPhase = .starting,
    active_connections: u32 = 0,
    pending_handoffs: u32 = 0,
    notification_armed: bool = false,
};

pub const Statistics = struct {
    accepted: u64 = 0,
    completions: u64 = 0,
    receives: u64 = 0,
    sends: u64 = 0,
    bytes: u64 = 0,
};

pub const Request = struct {
    connection: ?*Connection = null,
    operation: EngineOperation = .receive,
};

pub const Connection = struct {
    owner: ?*Worker = null,
    socket: c.SOCKET = c.INVALID_SOCKET,
    request_queue: c.RIO_RQ = c.RIO_INVALID_RQ,
    buffer: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
    request: Request = .{},
    echo_bytes: usize = 0,
    send_offset: usize = 0,
    index: u32 = 0,
    outstanding: u32 = 0,
    deadline: u64 = 0,
    active: bool = false,
    closing: bool = false,
};

pub const Worker = struct {
    resources: ?*anyopaque = null,
    rio_api: ?*const rio.Api = null,
    options: ?*const types.Options = null,
    failed: ?*std.atomic.Value(bool) = null,
    port: c.HANDLE = null,
    thread: c.HANDLE = null,
    ready_event: c.HANDLE = null,
    notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
    completion_queue: c.RIO_CQ = c.RIO_INVALID_CQ,
    registration: c.RIO_BUFFERID = c.RIO_INVALID_BUFFERID,
    memory: ?[*]u8 = null,
    connections: ?[*]Connection = null,
    free_indices: ?[*]u32 = null,
    timer_nodes: ?[*]timer_heap.Node = null,
    timer_positions: ?[*]u32 = null,
    timers: ?timer_heap.Heap = null,
    slot_count: u32 = 0,
    free_count: u32 = 0,
    active_count: u32 = 0,
    stride: u32 = 0,
    worker_index: u32 = 0,
    statistics: Statistics = .{},
    notification_armed: bool = false,
    stopping: bool = false,
    admission_closed: bool = false,
    ready: bool = false,
};

pub const accept_address_bytes: usize = (@sizeOf(c.SOCKADDR_STORAGE) + 16) * 2;

pub const AcceptOperation = struct {
    overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
    owner: ?*Acceptor = null,
    socket: c.SOCKET = c.INVALID_SOCKET,
    socket_owner: win32.Socket = .{},
    accept_port: c.HANDLE = null,
    state: AcceptState = .idle,
    index: u32 = 0,
    addresses: [accept_address_bytes]u8 = @splat(0),
};

pub const Acceptor = struct {
    resources: ?*anyopaque = null,
    rio_api: ?*const rio.Api = null,
    options: ?*const types.Options = null,
    workers: ?[*]Worker = null,
    worker_count: u32 = 0,
    failed: ?*std.atomic.Value(bool) = null,
    port: c.HANDLE = null,
    thread: c.HANDLE = null,
    ready_event: c.HANDLE = null,
    listener: c.SOCKET = c.INVALID_SOCKET,
    accept_ex: ?c.LPFN_ACCEPTEX = null,
    get_accept_addresses: ?c.LPFN_GETACCEPTEXSOCKADDRS = null,
    operations: ?[*]AcceptOperation = null,
    operation_count: u32 = 0,
    next_worker: u32 = 0,
    stopping: bool = false,
    ready: bool = false,
    startup_ok: bool = false,
};

pub const UdpSlot = struct {
    payload: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
    remote_address: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
    operation: EngineOperation = .receive,
    outstanding: bool = false,
};

pub fn workerMayExit(lifecycle: *const WorkerLifecycle) bool {
    return @backingInt(lifecycle.phase) >= @backingInt(WorkerPhase.admission_closed) and
        lifecycle.active_connections == 0 and lifecycle.pending_handoffs == 0;
}

pub fn udpMayRelease(phase: UdpPhase, outstanding: u32) bool {
    return phase == .stopped and outstanding == 0;
}

pub fn notificationPacketMatches(key: usize, overlapped: ?*c.OVERLAPPED, expected_key: usize, expected: ?*c.OVERLAPPED) bool {
    return key == expected_key and overlapped == expected;
}

pub fn statisticsAdd(total: *Statistics, value: *const Statistics) void {
    total.accepted += value.accepted;
    total.completions += value.completions;
    total.receives += value.receives;
    total.sends += value.sends;
    total.bytes += value.bytes;
}

fn pointerInSlice(comptime T: type, pointer: *const T, values: []const T) bool {
    if (values.len == 0) return false;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(values.ptr);
    const end = start + values.len * @sizeOf(T);
    return address >= start and address < end and (address - start) % @sizeOf(T) == 0;
}

pub fn requestContextValid(request: *const Request, connections: []const Connection) bool {
    const connection = request.connection orelse return false;
    return pointerInSlice(Connection, connection, connections) and &connection.request == request;
}

pub fn acceptContextValid(operation: *const AcceptOperation, operations: []const AcceptOperation, owner: *const Acceptor) bool {
    return pointerInSlice(AcceptOperation, operation, operations) and operation.owner == owner;
}

pub fn udpContextValid(slot: *const UdpSlot, slots: []const UdpSlot) bool {
    return pointerInSlice(UdpSlot, slot, slots);
}
