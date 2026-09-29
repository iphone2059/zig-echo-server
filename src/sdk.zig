const std = @import("std");

/// Project-private declarations for the Windows APIs used by this executable.
/// Zig 0.17-dev removed `@cImport`; keeping the ABI surface explicit also makes
/// accidental growth of the native dependency boundary reviewable.
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
    pub const WSAECONNRESET: i32 = 10054;
    pub const WSAEINVAL: i32 = 10022;
    pub const SOMAXCONN: c_int = 0x7fffffff;

    pub const ERROR_SUCCESS: DWORD = 0;
    pub const ERROR_INVALID_DATA: DWORD = 13;
    pub const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
    pub const ERROR_INSUFFICIENT_BUFFER: DWORD = 122;
    pub const ERROR_ARITHMETIC_OVERFLOW: DWORD = 534;
    pub const ERROR_IO_INCOMPLETE: DWORD = 996;
    pub const ERROR_IO_PENDING: DWORD = 997;
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
    pub extern fn WSAGetOverlappedResult(socket: SOCKET, overlapped: *OVERLAPPED, transferred: *DWORD, wait: BOOL, flags: *DWORD) callconv(.winapi) BOOL;
    pub extern fn htons(value: u16) callconv(.winapi) u16;
    pub extern fn htonl(value: u32) callconv(.winapi) u32;

    pub extern fn GetLastError() callconv(.winapi) DWORD;
    pub extern fn GetCurrentProcess() callconv(.winapi) HANDLE;
    pub extern fn TerminateProcess(process: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
    pub extern fn GetStdHandle(which: DWORD) callconv(.winapi) HANDLE;
    pub extern fn WriteFile(handle: HANDLE, buffer: [*]const u8, bytes: DWORD, written: *DWORD, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
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
    pub extern fn Sleep(milliseconds: DWORD) callconv(.winapi) void;
    pub extern fn QueryPerformanceCounter(value: *LARGE_INTEGER) callconv(.winapi) BOOL;
    pub extern fn QueryPerformanceFrequency(value: *LARGE_INTEGER) callconv(.winapi) BOOL;
    pub extern fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
};
