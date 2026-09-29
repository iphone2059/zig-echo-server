const std = @import("std");
pub const c = @import("sdk.zig").c;

pub fn report(stage: []const u8, native_error: u32) void {
    std.debug.print("{s} failed: native_error={d}\n", .{ stage, native_error });
}

pub fn failFast(stage: []const u8, native_error: u32) noreturn {
    std.debug.print("fatal invariant: {s}, native_error={d}\n", .{ stage, native_error });
    std.process.exit(4);
}

pub const Winsock = struct {
    started: bool = false,

    pub fn init() !Winsock {
        var data: c.WSADATA = undefined;
        if (c.WSAStartup(0x0202, &data) != 0) return error.WsaStartup;
        return .{ .started = true };
    }

    pub fn deinit(self: *Winsock) void {
        if (self.started) {
            _ = c.WSACleanup();
            self.started = false;
        }
    }
};

pub const Socket = struct {
    value: c.SOCKET = c.INVALID_SOCKET,

    pub fn deinit(self: *Socket) void {
        if (self.value != c.INVALID_SOCKET) {
            _ = c.closesocket(self.value);
            self.value = c.INVALID_SOCKET;
        }
    }

    pub fn take(self: *Socket) c.SOCKET {
        const value = self.value;
        self.value = c.INVALID_SOCKET;
        return value;
    }
};

pub const Handle = struct {
    value: c.HANDLE = null,

    pub fn deinit(self: *Handle) void {
        if (self.value != null) {
            _ = c.CloseHandle(self.value);
            self.value = null;
        }
    }
};

pub const VirtualMemory = struct {
    ptr: ?*anyopaque = null,

    pub fn alloc(bytes: usize) !VirtualMemory {
        const p = c.VirtualAlloc(null, bytes, c.MEM_RESERVE | c.MEM_COMMIT, c.PAGE_READWRITE);
        if (p == null) return error.VirtualAlloc;
        return .{ .ptr = p };
    }

    pub fn bytes(self: *VirtualMemory) [*]u8 {
        return @ptrCast(self.ptr.?);
    }

    pub fn deinit(self: *VirtualMemory) void {
        if (self.ptr) |p| {
            _ = c.VirtualFree(p, 0, c.MEM_RELEASE);
            self.ptr = null;
        }
    }
};

pub fn registeredSocket(socket_type: c_int, protocol: c_int) c.SOCKET {
    return c.WSASocketW(c.AF_INET, socket_type, protocol, null, 0, c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO);
}

pub fn configureSocket(socket_value: c.SOCKET, socket_buffer_bytes: u32, tcp: bool) bool {
    if (socket_buffer_bytes != 0) {
        var size: c_int = @intCast(socket_buffer_bytes);
        const ptr: [*c]const u8 = @ptrCast(&size);
        if (c.setsockopt(socket_value, c.SOL_SOCKET, c.SO_SNDBUF, ptr, @intCast(@sizeOf(c_int))) != 0 or
            c.setsockopt(socket_value, c.SOL_SOCKET, c.SO_RCVBUF, ptr, @intCast(@sizeOf(c_int))) != 0)
        {
            report("setsockopt(SO_SNDBUF/SO_RCVBUF)", @intCast(c.WSAGetLastError()));
            return false;
        }
    }
    if (tcp) {
        var enabled: c.BOOL = c.TRUE;
        const ptr: [*c]const u8 = @ptrCast(&enabled);
        if (c.setsockopt(socket_value, c.IPPROTO_TCP, c.TCP_NODELAY, ptr, @intCast(@sizeOf(c.BOOL))) != 0) {
            report("setsockopt(TCP_NODELAY)", @intCast(c.WSAGetLastError()));
            return false;
        }
    }
    return true;
}
