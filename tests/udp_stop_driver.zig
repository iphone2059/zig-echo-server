const std = @import("std");
const server = @import("server");
const c = server.win32.c;

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
        .rio_buffer_bytes = server.types.max_udp_payload,
        .cq_capacity = 256,
        .memory_bytes = 67108864,
        .quiet = true,
        .stats = true,
    };
    var winsock = server.win32.Winsock.init() catch return 2;
    defer winsock.deinit();
    var api = server.rio.Api.load() catch return 2;
    var stop = std.atomic.Value(bool).init(false);
    const thread = std.Thread.spawn(.{}, requestStop, .{&stop}) catch return 4;
    defer thread.join();
    return @backingInt(server.udp.run(&api, &options, &stop));
}
