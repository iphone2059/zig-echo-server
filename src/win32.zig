const std = @import("std");
pub const c = @import("sdk.zig").c;

fn writeAll(handle: c.HANDLE, bytes: []const u8) bool {
    if (handle == null or handle == c.INVALID_HANDLE_VALUE) return false;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const amount: c.DWORD = @intCast(@min(remaining, std.math.maxInt(c.DWORD)));
        var written: c.DWORD = 0;
        if (c.WriteFile(handle, bytes[offset..].ptr, amount, &written, null) == c.FALSE or written == 0) return false;
        offset += written;
    }
    return true;
}

pub fn writeStdout(bytes: []const u8) bool {
    return writeAll(c.GetStdHandle(c.STD_OUTPUT_HANDLE), bytes);
}

pub fn writeStderr(bytes: []const u8) bool {
    return writeAll(c.GetStdHandle(c.STD_ERROR_HANDLE), bytes);
}

pub fn reportNative(stage: []const u8, native_error: u32) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s} failed: native_error={d}\n", .{ stage, native_error }) catch return;
    _ = writeStderr(text);
}

pub const report = reportNative;

pub fn failFast(stage: []const u8, native_error: u32) noreturn {
    reportNative(stage, native_error);
    _ = c.TerminateProcess(c.GetCurrentProcess(), 4);
    unreachable;
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

    pub fn get(self: *const Socket) c.SOCKET {
        return self.value;
    }

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

    pub fn reset(self: *Socket, value: c.SOCKET) void {
        self.deinit();
        self.value = value;
    }
};

pub const Handle = struct {
    value: c.HANDLE = null,

    pub fn get(self: *const Handle) c.HANDLE {
        return self.value;
    }

    pub fn deinit(self: *Handle) void {
        if (self.value != null and self.value != c.INVALID_HANDLE_VALUE) {
            _ = c.CloseHandle(self.value);
        }
        self.value = null;
    }

    pub fn take(self: *Handle) c.HANDLE {
        const value = self.value;
        self.value = null;
        return value;
    }

    pub fn reset(self: *Handle, value: c.HANDLE) void {
        self.deinit();
        self.value = value;
    }
};

pub const ThreadHandle = Handle;
pub const EventHandle = Handle;

pub const VirtualMemory = struct {
    ptr: ?*anyopaque = null,

    pub fn get(self: *const VirtualMemory) ?*anyopaque {
        return self.ptr;
    }

    pub fn alloc(byte_count: usize) !VirtualMemory {
        const p = c.VirtualAlloc(null, byte_count, c.MEM_RESERVE | c.MEM_COMMIT, c.PAGE_READWRITE);
        if (p == null) return error.VirtualAlloc;
        return .{ .ptr = p };
    }

    pub fn bytes(self: *VirtualMemory) [*]u8 {
        return @ptrCast(self.ptr.?);
    }

    pub fn take(self: *VirtualMemory) ?*anyopaque {
        const value = self.ptr;
        self.ptr = null;
        return value;
    }

    pub fn reset(self: *VirtualMemory, value: ?*anyopaque) void {
        self.deinit();
        self.ptr = value;
    }

    pub fn deinit(self: *VirtualMemory) void {
        if (self.ptr) |p| {
            _ = c.VirtualFree(p, 0, c.MEM_RELEASE);
            self.ptr = null;
        }
    }
};

pub fn registeredSocketFlags() c.DWORD {
    return c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO;
}

pub fn registeredSocket(socket_type: c_int, protocol: c_int) c.SOCKET {
    return c.WSASocketW(c.AF_INET, socket_type, protocol, null, 0, registeredSocketFlags());
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
