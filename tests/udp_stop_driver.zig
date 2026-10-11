//! Starts a real datagram run and asks it to stop from another thread, so the controlled-stop path
//! is exercised end to end rather than only through a unit-level flag.

const std = @import("std");
const server = @import("server");
const c = server.native.sdk.c;

fn requestStop(stop: *std.atomic.Value(bool)) void {
    c.Sleep(750);
    stop.store(true, .release);
}

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 2) return 1;
    const port = std.fmt.parseInt(u16, argv[1], 10) catch return 1;
    var options: server.types.Options = .{
        .protocol = .udp,
        .port = port,
        .udp_depth = 64,
        .rio_buffer_bytes = @intCast(server.types.maximum_udp_payload),
        .cq_capacity = 256,
        .memory_bytes = 67108864,
        .quiet = true,
        .stats = true,
    };
    var winsock = server.native.winsock.Winsock.init() catch return 2;
    defer winsock.deinit();
    const api = server.native.rio.Api.load() catch return 2;
    var stop = std.atomic.Value(bool).init(false);
    const thread = std.Thread.spawn(.{}, requestStop, .{&stop}) catch return 4;
    defer thread.join();
    return @backingInt(server.udp.runtime.run(&api, &options, &stop));
}
