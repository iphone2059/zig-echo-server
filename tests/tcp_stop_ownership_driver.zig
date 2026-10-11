//! Observes the accept stop boundary against real threads, a real listener and a real completion.
//!
//! The sequence under test is the one that produced WSAENOTSOCK. A completed AcceptEx is moved to
//! transit and published to a worker's port; the stop then runs. A slot in transit has already left
//! the acceptor's ownership, so the stop must not close it -- the worker is about to take that same
//! socket, and closing it here both races the take() on one ownership record and hands the worker a
//! dead handle. Only a posted slot may be cancelled.
//!
//! The worker thread is deliberately not started. That keeps the published handoff in transit for the
//! rest of the round, so the boundary can be measured instead of raced: the socket in that slot is
//! queried directly, and an open socket means the stop left the handoff alone while a closed one means
//! it reached into a slot it no longer owned. The slot is found by scanning the table, because the
//! connection completes on whichever operation the operating system picks.

const std = @import("std");
const server = @import("server");
const c = server.native.sdk.c;
const acceptor = server.acceptor;
const tcp = server.tcp;

fn native_report(stage: []const u8, native_error: u32) void {
    server.native.diagnostics.report(stage, native_error);
}

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 3) return 1;
    const rounds = std.fmt.parseInt(u32, argv[1], 10) catch return 1;
    // One port for the whole run, chosen by the caller outside its ephemeral range: the listener is
    // released and rebound after every round, and Windows may reassign a port in that range while the
    // round is running, which would turn a bind collision into a spurious failure.
    const base_port = std.fmt.parseInt(u16, argv[2], 10) catch return 1;

    var options: server.types.Options = .{
        .protocol = .tcp,
        .port = 0,
        .timeout_seconds = 1,
        .run_seconds = 0,
        .worker_count = 1,
        .rio_buffer_bytes = 4096,
        .cq_capacity = 256,
        .memory_bytes = 67108864,
        .quiet = true,
    };

    const capacity = server.server.slotCapacity(&options, 1, 0);
    if (capacity == 0) return 2;
    var winsock = server.native.winsock.Winsock.init() catch return 2;
    defer winsock.deinit();
    const api = server.native.rio.Api.load() catch return 2;

    var failed = std.atomic.Value(bool).init(false);
    // The worker owns the storage a handoff names, but its thread never runs: the handoff stays in
    // transit for the whole round, which is what makes the boundary observable.
    var worker: server.internal.TcpWorker = .{};
    var credits: [1]acceptor.AdmissionCredits = .{acceptor.AdmissionCredits.init(capacity)};
    tcp.initialize(&worker, &api, &options, &failed, 0, capacity, &credits[0]) catch return 2;
    defer tcp.destroy(&worker);

    const worker_slice: []server.internal.TcpWorker = @as([*]server.internal.TcpWorker, @ptrCast(&worker))[0..1];
    var rounds_with_transit: u32 = 0;
    var closed_transit_sockets: u32 = 0;
    var connect_failures: u32 = 0;

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        options.port = base_port;
        var value: acceptor.Acceptor = .{};
        acceptor.initialize(&value, &api, &options, worker_slice, credits[0..], &failed) catch {
            // The caller chose this port, so a refusal here is reported rather than skipped: a round
            // that never ran must not be counted as a round that passed.
            native_report("bind", @intCast(c.WSAGetLastError()));
            return 2;
        };
        if (!acceptor.start(&value)) {
            acceptor.stop(&value);
            acceptor.destroy(&value);
            continue;
        }

        const client = c.WSASocketW(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP, null, 0, 0);
        var connected = false;
        if (client != c.INVALID_SOCKET) {
            var address: c.SOCKADDR_IN = std.mem.zeroes(c.SOCKADDR_IN);
            address.sin_family = c.AF_INET;
            address.sin_port = c.htons(options.port);
            address.sin_addr.S_un.S_addr = c.htonl(0x7F000001);
            connected = c.connect(client, @ptrCast(&address), @sizeOf(c.SOCKADDR_IN)) == 0;
        }

        // Wait for the completed connection to be published as a handoff, and learn which slot holds
        // it. The worker never runs, so once it is in transit it stays there.
        var transit_slot: ?u32 = null;
        if (connected) {
            var wait: u32 = 0;
            while (wait < 2000 and transit_slot == null) : (wait += 1) {
                var index: u32 = 0;
                while (index < value.operationCount()) : (index += 1) {
                    if (value.disposition(index) == .wait_ack) {
                        transit_slot = index;
                        break;
                    }
                }
                if (transit_slot == null) c.Sleep(1);
            }
        } else {
            connect_failures +%= 1;
        }

        acceptor.stop(&value);
        var begun: u32 = 0;
        while (begun < 2000 and !value.stopping()) : (begun += 1) c.Sleep(1);

        if (transit_slot) |index| {
            rounds_with_transit +%= 1;
            const socket_value = value.operations[index].socket;
            // getpeername is the handle test: a closed handle answers WSAENOTSOCK instead of a peer.
            var peer: c.SOCKADDR_STORAGE = std.mem.zeroes(c.SOCKADDR_STORAGE);
            var peer_length: c_int = @sizeOf(c.SOCKADDR_STORAGE);
            if (c.getpeername(socket_value, @ptrCast(&peer), &peer_length) != 0) closed_transit_sockets +%= 1;
            // No worker thread will acknowledge this handoff, so the round retires the slot itself.
            // The release boundary refuses to free a live slot, which is what makes the drain below
            // part of the assertion rather than tidiness.
            _ = value.core.returnSlot(index);
        }

        if (client != c.INVALID_SOCKET) _ = c.closesocket(client);
        var drained: u32 = 0;
        while (drained < 4000 and value.liveCount() != 0) : (drained += 1) c.Sleep(1);
        if (value.liveCount() != 0) return 4;
        acceptor.destroy(&value);
    }

    // Each transit round left one reservation unclaimed: the acceptor reserved a worker credit before
    // publishing the handoff, and no worker thread ever ran to consume it. The level has to be exactly
    // that, which is what proves the release path neither lost a reservation nor returned one twice.
    const claimed = rounds_with_transit;
    const available = credits[0].get();
    const credit_mismatch: u32 = if (available != capacity - claimed) 1 else 0;

    var buffer: [352]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "stop_ownership rounds={d} transit_rounds={d} closed_transit_sockets={d} connect_failures={d} claimed={d} available={d} capacity={d} credit_mismatch={d} failed={s}\n", .{
        rounds,
        rounds_with_transit,
        closed_transit_sockets,
        connect_failures,
        claimed,
        available,
        capacity,
        credit_mismatch,
        if (failed.load(.acquire)) "true" else "false",
    }) catch return 4;
    if (!server.native.diagnostics.writeStdout(text)) return 4;

    if (closed_transit_sockets != 0 or credit_mismatch != 0 or failed.load(.acquire)) return 2;
    return 0;
}
