const std = @import("std");
const server = @import("server");
const win32 = server.win32;
const rio = server.rio;
const c = win32.c;

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
