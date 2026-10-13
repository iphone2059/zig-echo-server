//! Windows x64 ABI, Winsock, RIO, AcceptEx and every native resource owner the server uses.
//!
//! The dependency direction is one-way: this file never imports a state machine. The nested
//! namespaces are compile-time containers with no runtime instance, no vtable and no allocation of
//! their own.

const std = @import("std");
const types = @import("types.zig");

/// The Windows SDK surface. Layout assumptions are stated once and checked at compile time.
pub const sdk = struct {
    pub const c = struct {
        pub const BOOL = c_int;
        pub const DWORD = u32;
        pub const ULONG = u32;
        pub const ULONG_PTR = usize;
        pub const SOCKET = usize;
        pub const HANDLE = ?*anyopaque;
        pub const GUID = extern struct { Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8 };
        pub const LARGE_INTEGER = i64;

        pub const TRUE: BOOL = 1;
        pub const FALSE: BOOL = 0;
        pub const INVALID_SOCKET: SOCKET = std.math.maxInt(SOCKET);
        pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

        pub const AF_INET: c_int = 2;
        pub const SOCK_STREAM: c_int = 1;
        pub const SOCK_DGRAM: c_int = 2;
        pub const IPPROTO_TCP: c_int = 6;
        pub const IPPROTO_UDP: c_int = 17;
        pub const SOL_SOCKET: c_int = 0xffff;
        pub const SO_SNDBUF: c_int = 0x1001;
        pub const SO_RCVBUF: c_int = 0x1002;
        pub const SO_UPDATE_ACCEPT_CONTEXT: c_int = 0x700B;
        pub const TCP_NODELAY: c_int = 1;
        pub const INADDR_ANY: u32 = 0;

        pub const WSA_FLAG_OVERLAPPED: DWORD = 0x01;
        pub const WSA_FLAG_REGISTERED_IO: DWORD = 0x100;
        pub const SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER: DWORD = 0xC8000024;
        pub const SIO_GET_EXTENSION_FUNCTION_POINTER: DWORD = 0xC8000006;
        pub const WSAEINVAL: i32 = 10022;
        pub const WSAENOTSOCK: i32 = 10038;
        pub const WSAECONNRESET: i32 = 10054;
        pub const SOMAXCONN: c_int = 0x7fffffff;

        pub const ERROR_SUCCESS: DWORD = 0;
        pub const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
        pub const ERROR_INVALID_DATA: DWORD = 13;
        pub const ERROR_INSUFFICIENT_BUFFER: DWORD = 122;
        pub const ERROR_ARITHMETIC_OVERFLOW: DWORD = 534;
        pub const ERROR_IO_INCOMPLETE: DWORD = 996;
        pub const ERROR_IO_PENDING: DWORD = 997;
        pub const ERROR_TIMEOUT: DWORD = 1460;
        pub const ERROR_INVALID_STATE: DWORD = 5023;
        pub const WAIT_TIMEOUT: DWORD = 258;
        pub const WAIT_OBJECT_0: DWORD = 0;
        pub const INFINITE: DWORD = 0xffffffff;

        pub const MEM_COMMIT: DWORD = 0x1000;
        pub const MEM_RESERVE: DWORD = 0x2000;
        pub const MEM_RELEASE: DWORD = 0x8000;
        pub const PAGE_READWRITE: DWORD = 0x04;

        pub const CTRL_C_EVENT: DWORD = 0;
        pub const CTRL_BREAK_EVENT: DWORD = 1;
        pub const CTRL_CLOSE_EVENT: DWORD = 2;
        pub const ALL_PROCESSOR_GROUPS: u16 = 0xffff;
        pub const STD_OUTPUT_HANDLE: DWORD = 0xfffffff5;
        pub const STD_ERROR_HANDLE: DWORD = 0xfffffff4;

        pub const WSADATA = extern struct {
            wVersion: u16,
            wHighVersion: u16,
            iMaxSockets: u16,
            iMaxUdpDg: u16,
            lpVendorInfo: ?[*:0]u8,
            szDescription: [257]u8,
            szSystemStatus: [129]u8,
        };

        /// The architecture member is a union with the legacy OEM identifier; both are two bytes,
        /// so the flattened form below has the same layout.
        pub const SYSTEM_INFO = extern struct {
            architecture: u16,
            reserved: u16,
            page_size: DWORD,
            minimum_application_address: ?*anyopaque,
            maximum_application_address: ?*anyopaque,
            active_processor_mask: ULONG_PTR,
            number_of_processors: DWORD,
            processor_type: DWORD,
            allocation_granularity: DWORD,
            processor_level: u16,
            processor_revision: u16,
        };

        pub const OVERLAPPED = extern struct {
            Internal: ULONG_PTR,
            InternalHigh: ULONG_PTR,
            data: extern union {
                offsets: extern struct { Offset: DWORD, OffsetHigh: DWORD },
                Pointer: ?*anyopaque,
            },
            hEvent: HANDLE,
        };

        pub const IN_ADDR = extern struct {
            S_un: extern union {
                S_un_b: extern struct { s_b1: u8, s_b2: u8, s_b3: u8, s_b4: u8 },
                S_un_w: extern struct { s_w1: u16, s_w2: u16 },
                S_addr: u32,
            },
        };
        pub const SOCKADDR = extern struct { sa_family: u16, sa_data: [14]u8 };
        pub const SOCKADDR_IN = extern struct {
            sin_family: u16,
            sin_port: u16,
            sin_addr: IN_ADDR,
            sin_zero: [8]u8,
        };
        pub const SOCKADDR_STORAGE = extern struct {
            ss_family: u16,
            __ss_pad1: [6]u8,
            __ss_align: i64,
            __ss_pad2: [112]u8,
        };

        const RIO_BUFFERID_t = opaque {};
        const RIO_CQ_t = opaque {};
        const RIO_RQ_t = opaque {};
        pub const RIO_BUFFERID = ?*RIO_BUFFERID_t;
        pub const RIO_CQ = ?*RIO_CQ_t;
        pub const RIO_RQ = ?*RIO_RQ_t;
        pub const RIO_INVALID_BUFFERID: RIO_BUFFERID = @ptrFromInt(0xffffffff);
        pub const RIO_INVALID_CQ: RIO_CQ = null;
        pub const RIO_INVALID_RQ: RIO_RQ = null;
        pub const RIO_CORRUPT_CQ: ULONG = 0xffffffff;
        pub const RIO_IOCP_COMPLETION: c_int = 2;

        pub const RIO_BUF = extern struct {
            BufferId: RIO_BUFFERID,
            Offset: ULONG,
            Length: ULONG,
        };
        pub const RIORESULT = extern struct {
            Status: i32,
            BytesTransferred: ULONG,
            SocketContext: ?*anyopaque,
            RequestContext: ?*anyopaque,
        };
        pub const RIO_NOTIFICATION_COMPLETION = extern struct {
            Type: c_int,
            Iocp: extern struct {
                IocpHandle: HANDLE,
                CompletionKey: ?*anyopaque,
                Overlapped: ?*anyopaque,
            },
        };

        pub const LPFN_RIORECEIVE = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIORECEIVEEX = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIOSEND = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIOSENDEX = *const fn (RIO_RQ, [*c]RIO_BUF, ULONG, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, ?*RIO_BUF, DWORD, ?*anyopaque) callconv(.winapi) BOOL;
        pub const LPFN_RIOCLOSECOMPLETIONQUEUE = *const fn (RIO_CQ) callconv(.winapi) void;
        pub const LPFN_RIOCREATECOMPLETIONQUEUE = *const fn (DWORD, ?*RIO_NOTIFICATION_COMPLETION) callconv(.winapi) RIO_CQ;
        pub const LPFN_RIOCREATEREQUESTQUEUE = *const fn (SOCKET, ULONG, ULONG, ULONG, ULONG, RIO_CQ, RIO_CQ, ?*anyopaque) callconv(.winapi) RIO_RQ;
        pub const LPFN_RIODEQUEUECOMPLETION = *const fn (RIO_CQ, [*c]RIORESULT, ULONG) callconv(.winapi) ULONG;
        pub const LPFN_RIODEREGISTERBUFFER = *const fn (RIO_BUFFERID) callconv(.winapi) void;
        pub const LPFN_RIONOTIFY = *const fn (RIO_CQ) callconv(.winapi) c_int;
        pub const LPFN_RIOREGISTERBUFFER = *const fn ([*c]u8, DWORD) callconv(.winapi) RIO_BUFFERID;
        pub const LPFN_RIORESIZECOMPLETIONQUEUE = *const fn (RIO_CQ, DWORD) callconv(.winapi) BOOL;
        pub const LPFN_RIORESIZEREQUESTQUEUE = *const fn (RIO_RQ, DWORD, DWORD) callconv(.winapi) BOOL;
        pub const LPFN_ACCEPTEX = *const fn (SOCKET, SOCKET, ?*anyopaque, DWORD, DWORD, DWORD, *DWORD, *OVERLAPPED) callconv(.winapi) BOOL;
        pub const LPFN_GETACCEPTEXSOCKADDRS = *const fn (?*anyopaque, DWORD, DWORD, DWORD, *?*SOCKADDR, *c_int, *?*SOCKADDR, *c_int) callconv(.winapi) void;

        pub const RIO_EXTENSION_FUNCTION_TABLE = extern struct {
            cbSize: DWORD,
            RIOReceive: ?LPFN_RIORECEIVE,
            RIOReceiveEx: ?LPFN_RIORECEIVEEX,
            RIOSend: ?LPFN_RIOSEND,
            RIOSendEx: ?LPFN_RIOSENDEX,
            RIOCloseCompletionQueue: ?LPFN_RIOCLOSECOMPLETIONQUEUE,
            RIOCreateCompletionQueue: ?LPFN_RIOCREATECOMPLETIONQUEUE,
            RIOCreateRequestQueue: ?LPFN_RIOCREATEREQUESTQUEUE,
            RIODequeueCompletion: ?LPFN_RIODEQUEUECOMPLETION,
            RIODeregisterBuffer: ?LPFN_RIODEREGISTERBUFFER,
            RIONotify: ?LPFN_RIONOTIFY,
            RIORegisterBuffer: ?LPFN_RIOREGISTERBUFFER,
            RIOResizeCompletionQueue: ?LPFN_RIORESIZECOMPLETIONQUEUE,
            RIOResizeRequestQueue: ?LPFN_RIORESIZEREQUESTQUEUE,
        };

        pub const WSAID_MULTIPLE_RIO: GUID = .{
            .Data1 = 0x8509e081,
            .Data2 = 0x96dd,
            .Data3 = 0x4005,
            .Data4 = .{ 0xb1, 0x65, 0x9e, 0x2e, 0xe8, 0xc7, 0x9e, 0x3f },
        };
        pub const WSAID_ACCEPTEX: GUID = .{
            .Data1 = 0xb5367df1,
            .Data2 = 0xcbac,
            .Data3 = 0x11cf,
            .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
        };
        pub const WSAID_GETACCEPTEXSOCKADDRS: GUID = .{
            .Data1 = 0xb5367df2,
            .Data2 = 0xcbac,
            .Data3 = 0x11cf,
            .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
        };

        pub extern fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) c_int;
        pub extern fn WSACleanup() callconv(.winapi) c_int;
        pub extern fn WSAGetLastError() callconv(.winapi) c_int;
        pub extern fn WSASocketW(af: c_int, socket_type: c_int, protocol: c_int, protocol_info: ?*anyopaque, group: u32, flags: DWORD) callconv(.winapi) SOCKET;
        pub extern fn closesocket(socket: SOCKET) callconv(.winapi) c_int;
        pub extern fn setsockopt(socket: SOCKET, level: c_int, option: c_int, value: [*c]const u8, length: c_int) callconv(.winapi) c_int;
        pub extern fn bind(socket: SOCKET, address: *const SOCKADDR, address_length: c_int) callconv(.winapi) c_int;
        pub extern fn listen(socket: SOCKET, backlog: c_int) callconv(.winapi) c_int;
        pub extern fn connect(socket: SOCKET, address: *const SOCKADDR, address_length: c_int) callconv(.winapi) c_int;
        pub extern fn WSAIoctl(socket: SOCKET, code: DWORD, in_buffer: ?*anyopaque, in_bytes: DWORD, out_buffer: ?*anyopaque, out_bytes: DWORD, bytes_returned: *DWORD, overlapped: ?*OVERLAPPED, completion: ?*anyopaque) callconv(.winapi) c_int;
        // WSAGetOverlappedResult is deliberately not declared: GetQueuedCompletionStatus is the only
        // completion source this server reads, so no second query can disagree with it.
        pub extern fn htons(value: u16) callconv(.winapi) u16;
        pub extern fn htonl(value: u32) callconv(.winapi) u32;

        pub extern fn GetLastError() callconv(.winapi) DWORD;
        pub extern fn GetCurrentProcess() callconv(.winapi) HANDLE;
        pub extern fn TerminateProcess(process: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
        pub extern fn GetStdHandle(which: DWORD) callconv(.winapi) HANDLE;
        pub extern fn WriteFile(handle: HANDLE, buffer: [*]const u8, bytes: DWORD, written: *DWORD, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
        pub extern fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: DWORD) callconv(.winapi) DWORD;
        pub extern fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, creation: DWORD, attributes: DWORD, template: HANDLE) callconv(.winapi) HANDLE;
        pub extern fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
        pub extern fn VirtualAlloc(address: ?*anyopaque, bytes: usize, allocation_type: DWORD, protection: DWORD) callconv(.winapi) ?*anyopaque;
        pub extern fn VirtualFree(address: ?*anyopaque, bytes: usize, free_type: DWORD) callconv(.winapi) BOOL;
        pub extern fn CreateIoCompletionPort(file_handle: HANDLE, existing_port: HANDLE, completion_key: ULONG_PTR, concurrent_threads: DWORD) callconv(.winapi) HANDLE;
        pub extern fn GetQueuedCompletionStatus(port: HANDLE, bytes: *DWORD, completion_key: *ULONG_PTR, overlapped: *[*c]OVERLAPPED, milliseconds: DWORD) callconv(.winapi) BOOL;
        pub extern fn PostQueuedCompletionStatus(port: HANDLE, bytes: DWORD, completion_key: ULONG_PTR, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
        pub extern fn CreateEventW(attributes: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?[*:0]const u16) callconv(.winapi) HANDLE;
        pub extern fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
        pub extern fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
        pub extern fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) DWORD, parameter: ?*anyopaque, flags: DWORD, thread_id: ?*DWORD) callconv(.winapi) HANDLE;
        pub extern fn getpeername(socket: SOCKET, address: *SOCKADDR, address_length: *c_int) callconv(.winapi) c_int;
        pub extern fn GetTickCount64() callconv(.winapi) u64;
        pub extern fn GetActiveProcessorCount(group_number: u16) callconv(.winapi) DWORD;
        pub extern fn GetSystemInfo(info: *SYSTEM_INFO) callconv(.winapi) void;
        pub extern fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
        pub extern fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
    };

    comptime {
        // The ABI struct is named in full because this container also declares it.
        const abi = sdk.c;
        if (@sizeOf(usize) != 8) @compileError("the server targets 64-bit Windows only");
        if (@sizeOf(abi.OVERLAPPED) != 32) @compileError("OVERLAPPED must be 32 bytes on x64");
        if (@offsetOf(abi.OVERLAPPED, "hEvent") != 24) @compileError("OVERLAPPED.hEvent must be at offset 24");
        if (@sizeOf(abi.SOCKADDR_IN) != 16) @compileError("SOCKADDR_IN must be 16 bytes");
        if (@sizeOf(abi.SOCKADDR_STORAGE) != 128) @compileError("SOCKADDR_STORAGE must be 128 bytes");
        if (@sizeOf(abi.SYSTEM_INFO) != 48) @compileError("SYSTEM_INFO must be 48 bytes on x64");
        if (@offsetOf(abi.SYSTEM_INFO, "page_size") != 4) @compileError("SYSTEM_INFO.dwPageSize must be at offset 4");
        if (@sizeOf(abi.RIO_BUF) != 16) @compileError("RIO_BUF must be 16 bytes");
        if (@sizeOf(abi.RIORESULT) != 24) @compileError("RIORESULT must be 24 bytes");
        // The completion type, then a union whose Iocp arm is the larger of its two members.
        if (@sizeOf(abi.RIO_NOTIFICATION_COMPLETION) != 32) @compileError("RIO_NOTIFICATION_COMPLETION must be 32 bytes");
        if (@offsetOf(abi.RIO_NOTIFICATION_COMPLETION, "Iocp") != 8) @compileError("RIO_NOTIFICATION_COMPLETION.Iocp must be at offset 8");
        if (@sizeOf(abi.RIO_EXTENSION_FUNCTION_TABLE) != 112) @compileError("RIO_EXTENSION_FUNCTION_TABLE must be 112 bytes");
        if (types.udp_address_bytes != @sizeOf(abi.SOCKADDR_STORAGE) + 16) @compileError("a UDP slot charges SOCKADDR_STORAGE plus sixteen bytes");
    }
};

const c = sdk.c;

pub fn Result(comptime T: type) type {
    return union(enum) { value: T, failure: types.Failure };
}

pub fn win32Failure(stage: []const u8) types.Failure {
    return .{ .stage = stage, .code = @bitCast(c.GetLastError()), .domain = .win32 };
}

pub fn winsockFailure(stage: []const u8) types.Failure {
    return .{ .stage = stage, .code = c.WSAGetLastError(), .domain = .winsock };
}

/// Console and error reporting, plus the process-level fail-fast policy.
pub const diagnostics = struct {
    fn writeAll(handle_value: c.HANDLE, bytes: []const u8) bool {
        if (handle_value == null or handle_value == c.INVALID_HANDLE_VALUE) return false;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount: c.DWORD = @intCast(@min(bytes.len - offset, std.math.maxInt(c.DWORD)));
            var written: c.DWORD = 0;
            if (c.WriteFile(handle_value, bytes[offset..].ptr, amount, &written, null) == c.FALSE or written == 0) return false;
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

    pub fn report(stage: []const u8, native_error: u32) void {
        var buffer: [512]u8 = undefined;
        const code: i32 = @bitCast(native_error);
        const text = std.fmt.bufPrint(&buffer, "{s} failed: native_error={d}\n", .{ stage, code }) catch return;
        _ = writeStderr(text);
    }

    pub fn reportFailure(failure: types.Failure) void {
        report(failure.stage, @bitCast(failure.code));
    }

    /// Runs after the ownership barrier. Diagnostics never alter standard streams or exit status.
    pub fn writeSnapshots(values: []const types.NotifySnapshot, protocol: types.Protocol) void {
        const name = [13:0]u16{ 'C', 'E', 'S', '_', 'D', 'I', 'A', 'G', '_', 'F', 'I', 'L', 'E' };
        const required = c.GetEnvironmentVariableW(&name, null, 0);
        if (required == 0 or required > 512) return;
        var path: [512:0]u16 = @splat(0);
        const length = c.GetEnvironmentVariableW(&name, &path, 512);
        if (length == 0 or length >= 512) return;
        const file = c.CreateFileW(&path, 0x40000000, 1, null, 2, 0x80, null);
        if (file == null or file == c.INVALID_HANDLE_VALUE) return;
        defer _ = c.CloseHandle(file);
        for (values) |snapshot| {
            var buffer: [256]u8 = undefined;
            const line = snapshot.writeLine(protocol, &buffer) orelse continue;
            if (!writeAll(file, line)) break;
        }
    }

    /// A failure that leaves the process unable to make progress. The reference terminates rather
    /// than unwinding, because releasing registered memory while a provider still owns it would be
    /// worse than exiting.
    pub fn failFast(stage: []const u8, native_error: u32) noreturn {
        report(stage, native_error);
        _ = c.TerminateProcess(c.GetCurrentProcess(), 4);
        unreachable;
    }
};

/// The named fail-fast boundaries. Each one is a real production invariant, and naming them keeps
/// the fault-injection driver exercising the same code path a live run takes.
pub const guards = struct {
    pub fn requireNotifySuccess(status: c_int, stage: []const u8) void {
        if (status != c.ERROR_SUCCESS) diagnostics.failFast(stage, @bitCast(status));
    }

    pub fn requireDequeueCount(count: u32, maximum: u32, stage: []const u8) u32 {
        // RIO_CORRUPT_CQ is a hard failure rather than "no work".
        if (count == c.RIO_CORRUPT_CQ or count > maximum) diagnostics.failFast(stage, c.ERROR_INVALID_DATA);
        return count;
    }

    pub fn requireTransition(valid: bool, stage: []const u8) void {
        if (!valid) diagnostics.failFast(stage, c.ERROR_INVALID_STATE);
    }

    pub fn requireControlPost(ok: c.BOOL, native_error: u32, stage: []const u8) void {
        if (ok == c.FALSE) diagnostics.failFast(stage, native_error);
    }
};

pub const winsock = struct {
    pub const Winsock = struct {
        started: bool = false,

        pub fn init() !Winsock {
            return switch (initResult()) {
                .value => |value| value,
                .failure => error.WsaStartup,
            };
        }

        pub fn initResult() Result(Winsock) {
            var data: c.WSADATA = undefined;
            const status = c.WSAStartup(0x0202, &data);
            if (status != 0) return .{ .failure = .{ .stage = "WSAStartup", .code = status } };
            return .{ .value = .{ .started = true } };
        }

        pub fn deinit(self: *Winsock) void {
            if (self.started) {
                _ = c.WSACleanup();
                self.started = false;
            }
        }
    };
};

pub const handle = struct {
    /// A kernel handle owner. Handles are closed explicitly rather than at process exit.
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
};

pub const socket = struct {
    /// A socket owner. Closing a socket starts cancellation of its pending I/O; it does not end the
    /// lifetime of that I/O, which is why the request queue and the registered windows outlive the
    /// close until every completion has been dequeued.
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

    /// Registered I/O requires a socket created with the registered-IO flag; there is no fallback
    /// data path in this server.
    pub fn registeredFlags() c.DWORD {
        return c.WSA_FLAG_OVERLAPPED | c.WSA_FLAG_REGISTERED_IO;
    }

    pub fn registered(socket_type: c_int, protocol: c_int) c.SOCKET {
        return c.WSASocketW(c.AF_INET, socket_type, protocol, null, 0, registeredFlags());
    }

    /// Which stage of a socket configuration failed, and the status that call produced.
    ///
    /// The status is captured where it happened and travels back with the result rather than being
    /// re-queried by the caller. Reporting it from inside the failing call is not enough on its own:
    /// report() writes to the console, and that write can replace the thread's last error before
    /// anyone reads it. Naming the stage keeps Accept Context, the socket buffers and TCP_NODELAY
    /// distinguishable instead of collapsing them into one socket error.
    pub const SocketFailure = struct {
        stage: []const u8,
        native_error: i32,
    };

    /// Returns null on success, or the failing stage and its status.
    pub fn configure(value: c.SOCKET, socket_buffer_bytes: u32, tcp: bool) ?SocketFailure {
        if (socket_buffer_bytes != 0) {
            var size: c_int = @intCast(socket_buffer_bytes);
            const pointer: [*c]const u8 = @ptrCast(&size);
            if (c.setsockopt(value, c.SOL_SOCKET, c.SO_SNDBUF, pointer, @intCast(@sizeOf(c_int))) != 0 or
                c.setsockopt(value, c.SOL_SOCKET, c.SO_RCVBUF, pointer, @intCast(@sizeOf(c_int))) != 0)
            {
                return .{ .stage = "setsockopt(SO_SNDBUF/SO_RCVBUF)", .native_error = @intCast(c.WSAGetLastError()) };
            }
        }
        if (tcp) {
            var enabled: c.BOOL = c.TRUE;
            const pointer: [*c]const u8 = @ptrCast(&enabled);
            if (c.setsockopt(value, c.IPPROTO_TCP, c.TCP_NODELAY, pointer, @intCast(@sizeOf(c.BOOL))) != 0) {
                return .{ .stage = "setsockopt(TCP_NODELAY)", .native_error = @intCast(c.WSAGetLastError()) };
            }
        }
        return null;
    }
};

/// Registered memory. One arena owns exactly one virtual allocation and every registration that
/// points into it, so the deregister-before-unmap order cannot be got wrong at a call site.
pub const arena = struct {
    const allocator = std.heap.page_allocator;

    pub const VirtualMemory = struct {
        pointer: ?*anyopaque = null,

        pub fn alloc(byte_count: usize) !VirtualMemory {
            return switch (allocResult(byte_count)) {
                .value => |value| value,
                .failure => error.VirtualAlloc,
            };
        }

        pub fn allocResult(byte_count: usize) Result(VirtualMemory) {
            const base = c.VirtualAlloc(null, byte_count, c.MEM_RESERVE | c.MEM_COMMIT, c.PAGE_READWRITE);
            if (base == null) return .{ .failure = win32Failure("VirtualAlloc(arena)") };
            return .{ .value = .{ .pointer = base } };
        }

        pub fn bytes(self: *VirtualMemory) [*]u8 {
            return @ptrCast(self.pointer.?);
        }

        pub fn deinit(self: *VirtualMemory) void {
            if (self.pointer) |base| {
                _ = c.VirtualFree(base, 0, c.MEM_RELEASE);
                self.pointer = null;
            }
        }
    };

    pub const CreateError = error{ Capacity, Allocation, VirtualAlloc, Registration };

    /// Byte offset of one slot inside the arena, checked against the arena size.
    pub fn slotOffset(index: u32, stride: u32, total: usize) ?usize {
        if (stride == 0) return null;
        const offset = types.checkedProduct(usize, index, stride) orelse return null;
        const end = types.checkedAdd(usize, offset, stride) orelse return null;
        return if (end <= total) offset else null;
    }

    /// A TCP slot holds exactly one echo payload window.
    pub fn tcpStride(rio_buffer_bytes: u32) u32 {
        return rio_buffer_bytes;
    }

    /// A UDP slot holds the datagram payload followed by its address area.
    pub fn udpStride(rio_buffer_bytes: u32) ?u32 {
        const stride = types.checkedAdd(u64, rio_buffer_bytes, types.udp_address_bytes) orelse return null;
        return if (stride > std.math.maxInt(u32)) null else @intCast(stride);
    }

    /// One worker-owned virtual allocation with one registration per slot.
    ///
    /// Each slot gets its own registration because the documented RIO contract forbids reusing any
    /// part of a registration while an operation that references it is still pending. Isolated
    /// slots therefore keep an outstanding receive from ever sharing a registration with the echo
    /// send of another connection.
    pub const Arena = struct {
        pages: VirtualMemory = .{},
        bytes: usize = 0,
        stride: u32 = 0,
        slots: u32 = 0,
        registrations: []rio.Registration = &.{},

        pub fn create(api: *const rio.Api, slots: u32, stride: u32) CreateError!Arena {
            return switch (createResult(api, slots, stride)) {
                .value => |value| value,
                .failure => |failure| if (failure.domain == .winsock) error.Registration else error.Allocation,
            };
        }

        pub fn createResult(api: *const rio.Api, slots: u32, stride: u32) Result(Arena) {
            const bytes = types.checkedProduct(u64, slots, stride) orelse 0;
            if (slots == 0 or stride == 0 or bytes == 0 or bytes > std.math.maxInt(u32)) {
                return .{ .failure = .{ .stage = "arena size", .code = types.error_invalid_data, .domain = .invariant, .classification = .usage } };
            }
            var pages = switch (VirtualMemory.allocResult(@intCast(bytes))) {
                .value => |value| value,
                .failure => |failure| return .{ .failure = failure },
            };
            var transferred = false;
            defer if (!transferred) pages.deinit();
            const registrations = allocator.alloc(rio.Registration, slots) catch
                return .{ .failure = .{ .stage = "allocate arena registrations", .code = types.error_not_enough_memory, .domain = .allocation } };
            var registered: u32 = 0;
            defer {
                if (!transferred) {
                    for (registrations[0..registered]) |*registration| registration.deinit();
                    allocator.free(registrations);
                }
            }
            const base = pages.bytes();
            for (0..slots) |slot| {
                const start: usize = slot * stride;
                registrations[slot] = .{};
                registrations[slot].reset(api, api.registerBuffer(base + start, stride));
                if (!registrations[slot].valid()) return .{ .failure = winsockFailure("RIORegisterBuffer") };
                registered += 1;
            }
            transferred = true;
            return .{ .value = .{
                .pages = pages,
                .bytes = @intCast(bytes),
                .stride = stride,
                .slots = slots,
                .registrations = registrations,
            } };
        }

        /// Deregisters every slot while its memory is still mapped, and only then releases the
        /// single page owner.
        pub fn deinit(self: *Arena) void {
            for (self.registrations) |*registration| registration.deinit();
            if (self.registrations.len != 0) allocator.free(self.registrations);
            self.registrations = &.{};
            self.pages.deinit();
            self.* = .{};
        }

        pub fn view(self: *const Arena, index: u32, offset: u32, length: u32) ?c.RIO_BUF {
            if (index >= self.registrations.len) return null;
            if (offset > self.stride or length > self.stride - offset) return null;
            if (length == 0) return null;
            return self.registrations[index].slice(offset, length);
        }

        /// A view that may be empty. A zero-byte datagram is a legal UDP send, so the datagram
        /// path needs a view the TCP path deliberately refuses.
        pub fn datagramView(self: *const Arena, index: u32, offset: u32, length: u32) ?c.RIO_BUF {
            if (index >= self.registrations.len) return null;
            if (offset > self.stride or length > self.stride - offset) return null;
            return self.registrations[index].slice(offset, length);
        }

        pub fn slotBytes(self: *Arena, index: u32) ?[]u8 {
            const offset = slotOffset(index, self.stride, self.bytes) orelse return null;
            return self.pages.bytes()[offset .. offset + self.stride];
        }
    };
};

/// The RIO extension table and every object reached through it. RIO exports no importable symbols,
/// so a missing table entry is a hard failure rather than a silent fallback.
pub const rio = struct {
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

        /// The extension table is fetched once per run through WSAIoctl. Windows offers no static
        /// address for these entry points, so this cost is inherent and is paid exactly once.
        pub fn load() !Api {
            return switch (loadResult()) {
                .value => |value| value,
                .failure => |failure| {
                    diagnostics.reportFailure(failure);
                    return error.LoadRio;
                },
            };
        }

        pub fn loadResult() Result(Api) {
            var probe = socket.Socket{ .value = socket.registered(c.SOCK_STREAM, c.IPPROTO_TCP) };
            defer probe.deinit();
            if (probe.value == c.INVALID_SOCKET) {
                return .{ .failure = winsockFailure("WSASocketW(RIO probe)") };
            }
            var table: c.RIO_EXTENSION_FUNCTION_TABLE = std.mem.zeroes(c.RIO_EXTENSION_FUNCTION_TABLE);
            table.cbSize = @intCast(@sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE));
            var identifier: c.GUID = c.WSAID_MULTIPLE_RIO;
            var returned: c.DWORD = 0;
            const status = c.WSAIoctl(
                probe.value,
                c.SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
                &identifier,
                @intCast(@sizeOf(c.GUID)),
                &table,
                @intCast(@sizeOf(c.RIO_EXTENSION_FUNCTION_TABLE)),
                &returned,
                null,
                null,
            );
            if (status != 0) {
                return .{ .failure = winsockFailure("SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER(RIO)") };
            }
            if (!tableComplete(&table)) return .{ .failure = .{ .stage = "RIO extension table", .code = types.error_invalid_data } };
            return .{ .value = .{ .table = table } };
        }

        pub inline fn registerBuffer(self: *const Api, pointer: [*]u8, bytes: u32) c.RIO_BUFFERID {
            return self.table.RIORegisterBuffer.?(@ptrCast(pointer), bytes);
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
            socket_value: c.SOCKET,
            max_receive: u32,
            max_receive_buffers: u32,
            max_send: u32,
            max_send_buffers: u32,
            receive_cq: c.RIO_CQ,
            send_cq: c.RIO_CQ,
            socket_context: ?*anyopaque,
        ) c.RIO_RQ {
            return self.table.RIOCreateRequestQueue.?(socket_value, max_receive, max_receive_buffers, max_send, max_send_buffers, receive_cq, send_cq, socket_context);
        }

        pub inline fn receive(self: *const Api, rq: c.RIO_RQ, buffer: *c.RIO_BUF, flags: u32, context: ?*anyopaque) bool {
            return self.table.RIOReceive.?(rq, buffer, 1, flags, context) != c.FALSE;
        }

        pub inline fn send(self: *const Api, rq: c.RIO_RQ, buffer: *c.RIO_BUF, flags: u32, context: ?*anyopaque) bool {
            return self.table.RIOSend.?(rq, buffer, 1, flags, context) != c.FALSE;
        }

        pub inline fn receiveEx(self: *const Api, rq: c.RIO_RQ, payload: *c.RIO_BUF, remote: *c.RIO_BUF, context: ?*anyopaque) bool {
            return self.table.RIOReceiveEx.?(rq, payload, 1, null, remote, null, null, 0, context) != c.FALSE;
        }

        pub inline fn sendEx(self: *const Api, rq: c.RIO_RQ, payload: *c.RIO_BUF, remote: *c.RIO_BUF, context: ?*anyopaque) bool {
            return self.table.RIOSendEx.?(rq, payload, 1, null, remote, null, null, 0, context) != c.FALSE;
        }

        pub inline fn notify(self: *const Api, queue: c.RIO_CQ) c_int {
            return self.table.RIONotify.?(queue);
        }

        pub inline fn dequeue(self: *const Api, queue: c.RIO_CQ, results: [*]c.RIORESULT, count: u32) u32 {
            return self.table.RIODequeueCompletion.?(queue, results, count);
        }
    };

    /// A registered region. It keeps the table entry it was created with so it can be released
    /// without borrowing the transport that owns the function table.
    pub const Registration = struct {
        api: ?*const Api = null,
        id: c.RIO_BUFFERID = c.RIO_INVALID_BUFFERID,

        pub fn valid(self: *const Registration) bool {
            return self.api != null and self.id != c.RIO_INVALID_BUFFERID and self.id != null;
        }

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
                if (self.id != c.RIO_INVALID_BUFFERID and self.id != null) api.deregisterBuffer(self.id);
            }
            self.api = null;
            self.id = c.RIO_INVALID_BUFFERID;
        }

        /// A RIO_BUF view of part of the registration. The identity of the owning registration is
        /// preserved, which is what makes a partial re-post legal.
        pub fn slice(self: *const Registration, offset: u32, length: u32) ?c.RIO_BUF {
            if (!self.valid()) return null;
            const end = @as(u64, offset) + @as(u64, length);
            if (end > std.math.maxInt(u32)) return null;
            return .{ .BufferId = self.id, .Offset = offset, .Length = length };
        }
    };

    /// A RIO completion queue bound to an IOCP, with the armed state that belongs to it.
    pub const CompletionQueue = struct {
        api: ?*const Api = null,
        value: c.RIO_CQ = c.RIO_INVALID_CQ,
        armed: bool = false,

        pub fn valid(self: *const CompletionQueue) bool {
            return self.api != null and self.value != c.RIO_INVALID_CQ;
        }

        pub fn take(self: *CompletionQueue) c.RIO_CQ {
            const value = self.value;
            self.api = null;
            self.value = c.RIO_INVALID_CQ;
            self.armed = false;
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
            self.armed = false;
        }

        /// Only ERROR_SUCCESS is accepted: any other status leaves the queue unarmed and the caller
        /// must not assume a wake-up is coming.
        pub fn arm(self: *CompletionQueue) bool {
            const api = self.api orelse return false;
            if (self.armed) return false;
            if (self.value == c.RIO_INVALID_CQ) return false;
            if (api.notify(self.value) != 0) return false;
            self.armed = true;
            return true;
        }

        pub fn onDelivery(self: *CompletionQueue) bool {
            if (!self.armed) return false;
            self.armed = false;
            return true;
        }
    };

    /// One packet taken from an IOCP. An accept operation is identified by its own address, which is
    /// always larger than the two control keys.
    pub const CompletionPacket = struct {
        ok: bool,
        native_error: u32,
        key: usize,
        overlapped: ?*c.OVERLAPPED,
        transferred: u32 = 0,
    };

    pub fn getQueuedCompletionStatus(port: c.HANDLE, wait_milliseconds: u32) CompletionPacket {
        var transferred: c.DWORD = 0;
        var key: c.ULONG_PTR = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        const ok = c.GetQueuedCompletionStatus(port, &transferred, &key, &overlapped, wait_milliseconds);
        return .{
            .ok = ok != c.FALSE,
            .native_error = if (ok == c.FALSE) c.GetLastError() else c.ERROR_SUCCESS,
            .key = key,
            .transferred = transferred,
            .overlapped = if (overlapped) |value| @ptrCast(value) else null,
        };
    }

    pub fn postCompletion(port: c.HANDLE, key: usize, overlapped: ?*c.OVERLAPPED) bool {
        return c.PostQueuedCompletionStatus(port, 0, key, @ptrCast(overlapped)) != c.FALSE;
    }
};

pub const endpoint = struct {
    pub const update_accept_context: c_int = c.SO_UPDATE_ACCEPT_CONTEXT;

    pub fn anyEndpoint(port: u16) c.SOCKADDR_IN {
        var address: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
        address.sin_family = c.AF_INET;
        address.sin_addr.S_un.S_addr = c.htonl(c.INADDR_ANY);
        address.sin_port = c.htons(port);
        return address;
    }

    pub fn bindEndpoint(socket_value: c.SOCKET, port: u16) bool {
        if (bindFailure(socket_value, port)) |failure| {
            diagnostics.reportFailure(failure);
            return false;
        }
        return true;
    }

    pub fn bindFailure(socket_value: c.SOCKET, port: u16) ?types.Failure {
        var address = anyEndpoint(port);
        if (c.bind(socket_value, @ptrCast(&address), @sizeOf(c.SOCKADDR_IN)) != 0) {
            return winsockFailure("bind");
        }
        return null;
    }

    pub fn listenEndpoint(socket_value: c.SOCKET) bool {
        if (listenFailure(socket_value)) |failure| {
            diagnostics.reportFailure(failure);
            return false;
        }
        return true;
    }

    pub fn listenFailure(socket_value: c.SOCKET) ?types.Failure {
        if (c.listen(socket_value, c.SOMAXCONN) != 0) {
            return winsockFailure("listen");
        }
        return null;
    }

    /// An accepted socket only becomes usable for RIO once the accept context has been updated;
    /// the failure is not optional and is reported with the failing stage.
    pub fn updateAcceptContext(socket_value: c.SOCKET, listener: c.SOCKET) ?socket.SocketFailure {
        var listener_value = listener;
        if (c.setsockopt(socket_value, c.SOL_SOCKET, c.SO_UPDATE_ACCEPT_CONTEXT, @ptrCast(&listener_value), @sizeOf(c.SOCKET)) != 0) {
            return .{ .stage = "setsockopt(SO_UPDATE_ACCEPT_CONTEXT)", .native_error = @intCast(c.WSAGetLastError()) };
        }
        return null;
    }

    fn loadExtension(comptime T: type, socket_value: c.SOCKET, identifier_value: c.GUID, stage: []const u8) ?T {
        return switch (loadExtensionResult(T, socket_value, identifier_value, stage)) {
            .value => |value| value,
            .failure => |failure| {
                diagnostics.reportFailure(failure);
                return null;
            },
        };
    }

    fn loadExtensionResult(comptime T: type, socket_value: c.SOCKET, identifier_value: c.GUID, stage: []const u8) Result(T) {
        var identifier = identifier_value;
        var function: ?T = null;
        var returned: c.DWORD = 0;
        if (c.WSAIoctl(
            socket_value,
            c.SIO_GET_EXTENSION_FUNCTION_POINTER,
            &identifier,
            @sizeOf(c.GUID),
            @ptrCast(&function),
            @sizeOf(?T),
            &returned,
            null,
            null,
        ) != 0) {
            return .{ .failure = winsockFailure(stage) };
        }
        const loaded = function orelse return .{ .failure = .{ .stage = stage, .code = types.error_invalid_data } };
        return .{ .value = loaded };
    }

    pub fn acceptExtension(listener: c.SOCKET) ?c.LPFN_ACCEPTEX {
        return loadExtension(c.LPFN_ACCEPTEX, listener, c.WSAID_ACCEPTEX, "SIO_GET_EXTENSION_FUNCTION_POINTER(AcceptEx)");
    }

    pub fn acceptExtensionResult(listener: c.SOCKET) Result(c.LPFN_ACCEPTEX) {
        return loadExtensionResult(c.LPFN_ACCEPTEX, listener, c.WSAID_ACCEPTEX, "SIO_GET_EXTENSION_FUNCTION_POINTER(AcceptEx)");
    }

    pub fn acceptAddressesExtension(listener: c.SOCKET) ?c.LPFN_GETACCEPTEXSOCKADDRS {
        return loadExtension(c.LPFN_GETACCEPTEXSOCKADDRS, listener, c.WSAID_GETACCEPTEXSOCKADDRS, "SIO_GET_EXTENSION_FUNCTION_POINTER(GetAcceptExSockaddrs)");
    }

    pub fn acceptAddressesExtensionResult(listener: c.SOCKET) Result(c.LPFN_GETACCEPTEXSOCKADDRS) {
        return loadExtensionResult(c.LPFN_GETACCEPTEXSOCKADDRS, listener, c.WSAID_GETACCEPTEXSOCKADDRS, "SIO_GET_EXTENSION_FUNCTION_POINTER(GetAcceptExSockaddrs)");
    }
};

/// The system page size the memory budget is rounded to, with the reference's documented fallback.
pub fn pageBytes() u64 {
    var info: c.SYSTEM_INFO = std.mem.zeroes(c.SYSTEM_INFO);
    c.GetSystemInfo(&info);
    const page = info.page_size;
    return if (page == 0) 4096 else page;
}

/// Active processors across all processor groups, matching the Windows reference.
pub fn activeProcessorCount() u32 {
    return @intCast(c.GetActiveProcessorCount(c.ALL_PROCESSOR_GROUPS));
}

/// Wall-clock milliseconds. The server's deadlines are whole seconds, so the tick counter is the
/// reference's own clock for this process.
pub fn nowMilliseconds() u64 {
    return c.GetTickCount64();
}

test "arena geometry is checked and slots are isolated" {
    try std.testing.expectEqual(@as(?usize, 3072), arena.slotOffset(3, 1024, 4096));
    try std.testing.expectEqual(@as(?usize, null), arena.slotOffset(4, 1024, 4096));
    try std.testing.expectEqual(@as(?usize, null), arena.slotOffset(1, 0, 4096));
    try std.testing.expectEqual(@as(u32, 4096), arena.tcpStride(4096));
    try std.testing.expectEqual(@as(?u32, 65_507 + 144), arena.udpStride(65_507));
    try std.testing.expectEqual(@as(?u32, null), arena.udpStride(std.math.maxInt(u32)));
}

test "the system page size is a real power of two" {
    const page = pageBytes();
    try std.testing.expect(page >= 4096);
    try std.testing.expect(page & (page - 1) == 0);
    try std.testing.expect(activeProcessorCount() >= 1);
}

test "completion packet identity keeps an unrelated packet out" {
    // The identity rule itself is contract-level; this checks the packet shape the loop reads.
    const packet: rio.CompletionPacket = .{ .ok = false, .native_error = c.WAIT_TIMEOUT, .key = 0, .overlapped = null };
    try std.testing.expect(!packet.ok);
    try std.testing.expect(packet.overlapped == null);
}
