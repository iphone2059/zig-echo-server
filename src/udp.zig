const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const rio_mod = @import("rio.zig");
const contract = @import("contract.zig");
const fault_guards = @import("fault_guards.zig");
const types = @import("types.zig");
const internal = @import("engine_internal.zig");

const batch_size: u32 = 256;
const address_bytes: u32 = @sizeOf(c.SOCKADDR_STORAGE) + 16;

const Slot = internal.UdpSlot;

const Statistics = struct {
    completions: u64 = 0,
    receives: u64 = 0,
    sends: u64 = 0,
    bytes: u64 = 0,
};

fn arm(api: *const rio_mod.Api, cq: c.RIO_CQ, overlapped: *c.OVERLAPPED, armed: *bool) void {
    if (armed.*) win32.failFast("duplicate UDP RIONotify", c.ERROR_INVALID_STATE);
    overlapped.* = std.mem.zeroes(c.OVERLAPPED);
    const status = api.notify(cq);
    fault_guards.requireNotifySuccess(status, "RIONotify(UDP)");
    fault_guards.requireTransition(contract.notificationMarkRearmed(armed), "UDP notification rearm transition");
}

pub fn run(api: *const rio_mod.Api, options: *const types.Options, stop: *std.atomic.Value(bool)) types.ExitCode {
    const stride64: u64 = @as(u64, options.rio_buffer_bytes) + address_bytes;
    if (stride64 > std.math.maxInt(u32)) return .network;
    const stride: u32 = @intCast(stride64);
    if (options.udp_depth > options.cq_capacity / 2) {
        win32.report("UDP queue capacity", c.ERROR_INSUFFICIENT_BUFFER);
        return .network;
    }
    const arena_bytes = contract.checkedArenaBytes(options.udp_depth, stride, options.memory_bytes) orelse {
        win32.report("UDP arena capacity", c.ERROR_NOT_ENOUGH_MEMORY);
        return .network;
    };
    if (arena_bytes > std.math.maxInt(u32)) {
        win32.report("UDP arena > DWORD", c.ERROR_ARITHMETIC_OVERFLOW);
        return .network;
    }

    var socket = win32.Socket{ .value = win32.registeredSocket(c.SOCK_DGRAM, c.IPPROTO_UDP) };
    defer socket.deinit();
    if (socket.value == c.INVALID_SOCKET) {
        win32.report("WSASocketW(UDP RIO)", @intCast(c.WSAGetLastError()));
        return .network;
    }
    if (!win32.configureSocket(socket.value, options.socket_buffer_bytes, false)) return .network;

    var port = win32.Handle{ .value = c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1) };
    defer port.deinit();
    if (port.value == null) {
        win32.report("CreateIoCompletionPort(UDP)", @intCast(c.GetLastError()));
        return .network;
    }

    var address: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
    address.sin_family = c.AF_INET;
    address.sin_addr.S_un.S_addr = c.htonl(c.INADDR_ANY);
    address.sin_port = c.htons(options.port);
    if (c.bind(socket.value, @ptrCast(&address), @intCast(@sizeOf(c.SOCKADDR_IN))) != 0) {
        win32.report("bind(UDP)", @intCast(c.WSAGetLastError()));
        return .network;
    }

    var memory = win32.VirtualMemory.alloc(arena_bytes) catch {
        win32.report("VirtualAlloc(UDP)", @intCast(c.GetLastError()));
        return .network;
    };
    defer memory.deinit();

    const allocator = std.heap.page_allocator;
    const slots = allocator.alloc(Slot, options.udp_depth) catch {
        win32.report("allocate UDP slots", c.ERROR_NOT_ENOUGH_MEMORY);
        return .network;
    };
    defer allocator.free(slots);
    @memset(slots, undefined);

    var registration = rio_mod.Registration{ .api = api, .id = api.registerBuffer(memory.bytes(), @intCast(arena_bytes)) };
    defer registration.deinit();
    if (registration.id == c.RIO_INVALID_BUFFERID) {
        win32.report("RIORegisterBuffer(UDP)", @intCast(c.WSAGetLastError()));
        return .network;
    }

    var notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED);
    var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
    notification.Type = c.RIO_IOCP_COMPLETION;
    notification.Iocp.IocpHandle = port.value;
    notification.Iocp.CompletionKey = @ptrCast(slots.ptr);
    notification.Iocp.Overlapped = &notification_overlapped;

    var cq = rio_mod.CompletionQueue{ .api = api, .value = api.createCq(options.cq_capacity, &notification) };
    defer cq.deinit();
    if (cq.value == c.RIO_INVALID_CQ) {
        win32.report("RIOCreateCompletionQueue(UDP)", @intCast(c.WSAGetLastError()));
        return .network;
    }

    const rq = api.createRq(socket.value, options.udp_depth, 1, options.udp_depth, 1, cq.value, cq.value, @ptrCast(slots.ptr));
    if (rq == c.RIO_INVALID_RQ) {
        win32.report("RIOCreateRequestQueue(UDP)", @intCast(c.WSAGetLastError()));
        return .network;
    }

    var outstanding: u32 = 0;
    for (slots, 0..) |*slot, index| {
        slot.* = .{
            .payload = .{ .BufferId = registration.id, .Offset = @intCast(index * @as(usize, stride)), .Length = options.rio_buffer_bytes },
            .remote_address = .{ .BufferId = registration.id, .Offset = @intCast(index * @as(usize, stride) + options.rio_buffer_bytes), .Length = address_bytes },
            .operation = .receive,
            .outstanding = true,
        };
        if (!api.receiveEx(rq, &slot.payload, &slot.remote_address, @ptrCast(slot))) {
            win32.report("RIOReceiveEx(UDP)", @intCast(c.WSAGetLastError()));
            slot.outstanding = false;
            socket.deinit();
            break;
        }
        outstanding += 1;
    }

    var armed = false;
    if (outstanding != 0) arm(api, cq.value, &notification_overlapped, &armed);
    var stats: Statistics = .{};
    var failed = outstanding != options.udp_depth;
    var closing = failed;
    const start = c.GetTickCount64();
    if (closing) socket.deinit();
    var results: [batch_size]c.RIORESULT = undefined;

    while (!closing or outstanding != 0) {
        if (!closing and (stop.load(.acquire) or (options.run_seconds != 0 and c.GetTickCount64() - start >= @as(u64, options.run_seconds) * 1000))) {
            closing = true;
            socket.deinit();
        }

        var transferred: c.DWORD = 0;
        var key: c.ULONG_PTR = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        const ok = c.GetQueuedCompletionStatus(port.value, &transferred, &key, &overlapped, 100);
        const err: u32 = if (ok == c.FALSE) @intCast(c.GetLastError()) else c.ERROR_SUCCESS;

        if (overlapped == &notification_overlapped) {
            if (ok == c.FALSE) win32.failFast("GetQueuedCompletionStatus(UDP notification)", err);
            if (key != @intFromPtr(slots.ptr)) win32.failFast("UDP RIO notification key", c.ERROR_INVALID_DATA);
            fault_guards.requireTransition(contract.notificationMarkDelivered(&armed), "UDP notification delivery transition");

            while (true) {
                const count = fault_guards.requireDequeueCount(api.dequeue(cq.value, &results, batch_size), batch_size, "RIODequeueCompletion(UDP)");
                if (count == 0) break;
                for (results[0..count]) |result| {
                    const raw = result.RequestContext orelse win32.failFast("UDP null RequestContext", c.ERROR_INVALID_DATA);
                    const slot: *Slot = @ptrCast(@alignCast(raw));
                    if (!internal.udpContextValid(slot, slots) or !slot.outstanding or outstanding == 0)
                        win32.failFast("UDP completion invariant", c.ERROR_INVALID_DATA);
                    slot.outstanding = false;
                    outstanding -= 1;
                    stats.completions += 1;
                    if (slot.operation == .receive) stats.receives += 1 else {
                        stats.sends += 1;
                        if (result.Status == c.ERROR_SUCCESS) stats.bytes += result.BytesTransferred;
                    }
                    if (closing) continue;

                    if (result.Status != c.ERROR_SUCCESS) {
                        if (result.Status == c.WSAECONNRESET) {
                            slot.operation = .receive;
                            slot.payload.Length = options.rio_buffer_bytes;
                        } else {
                            win32.report("UDP RIO completion", @intCast(result.Status));
                            failed = true;
                            closing = true;
                            socket.deinit();
                            continue;
                        }
                    } else if (slot.operation == .receive) {
                        slot.payload.Length = result.BytesTransferred;
                        slot.operation = .send;
                    } else {
                        slot.payload.Length = options.rio_buffer_bytes;
                        slot.operation = .receive;
                    }

                    const posted = if (slot.operation == .send)
                        api.sendEx(rq, &slot.payload, &slot.remote_address, @ptrCast(slot))
                    else
                        api.receiveEx(rq, &slot.payload, &slot.remote_address, @ptrCast(slot));
                    if (!posted) {
                        win32.report("UDP RIO repost", @intCast(c.WSAGetLastError()));
                        failed = true;
                        closing = true;
                        socket.deinit();
                        continue;
                    }
                    slot.outstanding = true;
                    outstanding += 1;
                }
            }
            if (outstanding != 0) arm(api, cq.value, &notification_overlapped, &armed);
        } else if (ok == c.FALSE and err != c.WAIT_TIMEOUT) {
            win32.failFast("GetQueuedCompletionStatus(UDP)", err);
        } else if (!(ok == c.FALSE and err == c.WAIT_TIMEOUT and overlapped == null)) {
            win32.failFast("unexpected UDP IOCP packet", c.ERROR_INVALID_DATA);
        }
    }

    if (armed) {
        if (c.PostQueuedCompletionStatus(port.value, 0, 0, &notification_overlapped) == c.FALSE)
            win32.failFast("PostQueuedCompletionStatus(UDP notification shutdown)", @intCast(c.GetLastError()));
        var transferred: c.DWORD = 0;
        var key: c.ULONG_PTR = 0;
        var overlapped: [*c]c.OVERLAPPED = null;
        if (c.GetQueuedCompletionStatus(port.value, &transferred, &key, &overlapped, 1000) == c.FALSE)
            win32.failFast("GetQueuedCompletionStatus(UDP notification shutdown)", @intCast(c.GetLastError()));
        if (key != 0 or overlapped != &notification_overlapped)
            win32.failFast("UDP notification shutdown packet", c.ERROR_INVALID_DATA);
        if (!contract.notificationMarkDelivered(&armed))
            win32.failFast("UDP notification shutdown transition", c.ERROR_INVALID_STATE);
    }
    if (outstanding != 0) win32.failFast("UDP cleanup with outstanding operations", c.ERROR_IO_INCOMPLETE);

    if (options.stats) {
        const elapsed = @max(@as(u64, 1), c.GetTickCount64() - start);
        const mib_per_sec = (@as(f64, @floatFromInt(stats.bytes)) * 1000.0) / (@as(f64, @floatFromInt(elapsed)) * 1024.0 * 1024.0);
        var output_buffer: [512]u8 = undefined;
        const output = std.fmt.bufPrint(&output_buffer, "final protocol=udp elapsed_ms={d} completions={d} receives={d} sends={d} bytes={d} MiB_per_sec={d:.2} outstanding={d}\n", .{
            elapsed, stats.completions, stats.receives, stats.sends, stats.bytes, mib_per_sec, outstanding,
        }) catch win32.failFast("format UDP statistics", c.ERROR_INSUFFICIENT_BUFFER);
        if (!win32.writeStdout(output)) win32.failFast("write UDP statistics", c.GetLastError());
    }
    return if (failed) .network else .success;
}
