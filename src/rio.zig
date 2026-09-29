const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;

pub const Api = struct {
    table: c.RIO_EXTENSION_FUNCTION_TABLE,

    pub fn tableComplete(table: *const c.RIO_EXTENSION_FUNCTION_TABLE) bool {
        return table.RIOReceive != null and table.RIOReceiveEx != null and table.RIOSend != null and
            table.RIOSendEx != null and table.RIOCloseCompletionQueue != null and
            table.RIOCreateCompletionQueue != null and table.RIOCreateRequestQueue != null and
            table.RIODequeueCompletion != null and table.RIODeregisterBuffer != null and
            table.RIONotify != null and table.RIORegisterBuffer != null and
            table.RIOResizeCompletionQueue != null and table.RIOResizeRequestQueue != null;
    }

    pub fn load() !Api {
        var probe = win32.Socket{ .value = win32.registeredSocket(c.SOCK_STREAM, c.IPPROTO_TCP) };
        defer probe.deinit();
        if (probe.value == c.INVALID_SOCKET) {
            win32.reportNative("WSASocketW(RIO probe)", @intCast(c.WSAGetLastError()));
            return error.ProbeSocket;
        }

        var table: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
        table.cbSize = @intCast(@sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE));
        var id: c.GUID = c.WSAID_MULTIPLE_RIO;
        var bytes: c.DWORD = 0;
        const status = c.WSAIoctl(
            probe.value,
            c.SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
            &id,
            @intCast(@sizeOf(c.GUID)),
            &table,
            @intCast(@sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE)),
            &bytes,
            null,
            null,
        );
        if (status != 0) {
            win32.report("SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER(RIO)", @intCast(c.WSAGetLastError()));
            return error.LoadRio;
        }
        if (!tableComplete(&table)) {
            win32.reportNative("RIO extension table", c.ERROR_INVALID_DATA);
            return error.InvalidRioTable;
        }
        return .{ .table = table };
    }

    pub inline fn registerBuffer(self: *const Api, ptr: [*]u8, bytes: u32) c.RIO_BUFFERID {
        return self.table.RIORegisterBuffer.?(@ptrCast(ptr), bytes);
    }

    pub inline fn deregisterBuffer(self: *const Api, id: c.RIO_BUFFERID) void {
        self.table.RIODeregisterBuffer.?(id);
    }

    pub inline fn createCq(self: *const Api, size: u32, notification: *c.RIO_NOTIFICATION_COMPLETION) c.RIO_CQ {
        return self.table.RIOCreateCompletionQueue.?(size, notification);
    }

    pub inline fn closeCq(self: *const Api, queue: c.RIO_CQ) void {
        self.table.RIOCloseCompletionQueue.?(queue);
    }

    pub inline fn createRq(
        self: *const Api,
        socket: c.SOCKET,
        max_recv: u32,
        max_recv_bufs: u32,
        max_send: u32,
        max_send_bufs: u32,
        recv_cq: c.RIO_CQ,
        send_cq: c.RIO_CQ,
        socket_context: ?*anyopaque,
    ) c.RIO_RQ {
        return self.table.RIOCreateRequestQueue.?(socket, max_recv, max_recv_bufs, max_send, max_send_bufs, recv_cq, send_cq, socket_context);
    }

    pub inline fn receive(self: *const Api, rq: c.RIO_RQ, buf: *c.RIO_BUF, flags: u32, ctx: ?*anyopaque) bool {
        return self.table.RIOReceive.?(rq, buf, 1, flags, ctx) != c.FALSE;
    }

    pub inline fn send(self: *const Api, rq: c.RIO_RQ, buf: *c.RIO_BUF, flags: u32, ctx: ?*anyopaque) bool {
        return self.table.RIOSend.?(rq, buf, 1, flags, ctx) != c.FALSE;
    }

    pub inline fn receiveEx(self: *const Api, rq: c.RIO_RQ, payload: *c.RIO_BUF, remote: *c.RIO_BUF, ctx: ?*anyopaque) bool {
        return self.table.RIOReceiveEx.?(rq, payload, 1, null, remote, null, null, 0, ctx) != c.FALSE;
    }

    pub inline fn sendEx(self: *const Api, rq: c.RIO_RQ, payload: *c.RIO_BUF, remote: *c.RIO_BUF, ctx: ?*anyopaque) bool {
        return self.table.RIOSendEx.?(rq, payload, 1, null, remote, null, null, 0, ctx) != c.FALSE;
    }

    pub inline fn notify(self: *const Api, cq: c.RIO_CQ) c_int {
        return self.table.RIONotify.?(cq);
    }

    pub inline fn dequeue(self: *const Api, cq: c.RIO_CQ, results: [*]c.RIORESULT, count: u32) u32 {
        return self.table.RIODequeueCompletion.?(cq, results, count);
    }
};

pub const Registration = struct {
    api: ?*const Api = null,
    id: c.RIO_BUFFERID = c.RIO_INVALID_BUFFERID,

    pub fn take(self: *Registration) c.RIO_BUFFERID {
        const value = self.id;
        self.api = null;
        self.id = c.RIO_INVALID_BUFFERID;
        return value;
    }

    pub fn reset(self: *Registration, api: ?*const Api, id: c.RIO_BUFFERID) void {
        self.deinit();
        self.api = api;
        self.id = id;
    }

    pub fn deinit(self: *Registration) void {
        if (self.api) |api| {
            if (self.id != c.RIO_INVALID_BUFFERID) api.deregisterBuffer(self.id);
        }
        self.api = null;
        self.id = c.RIO_INVALID_BUFFERID;
    }
};

pub const CompletionQueue = struct {
    api: ?*const Api = null,
    value: c.RIO_CQ = c.RIO_INVALID_CQ,

    pub fn take(self: *CompletionQueue) c.RIO_CQ {
        const value = self.value;
        self.api = null;
        self.value = c.RIO_INVALID_CQ;
        return value;
    }

    pub fn reset(self: *CompletionQueue, api: ?*const Api, value: c.RIO_CQ) void {
        self.deinit();
        self.api = api;
        self.value = value;
    }

    pub fn deinit(self: *CompletionQueue) void {
        if (self.api) |api| {
            if (self.value != c.RIO_INVALID_CQ) api.closeCq(self.value);
        }
        self.api = null;
        self.value = c.RIO_INVALID_CQ;
    }
};
