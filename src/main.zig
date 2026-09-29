const std = @import("std");
const sdk = @import("sdk.zig");
const c = sdk.c;
const types = @import("types.zig");
const options_mod = @import("options.zig");
const win32 = @import("win32.zig");
const rio = @import("rio.zig");
const udp = @import("udp.zig");

var stop_requested = std.atomic.Value(bool).init(false);

fn consoleHandler(kind: c.DWORD) callconv(.winapi) c.BOOL {
    if (kind == c.CTRL_C_EVENT or kind == c.CTRL_BREAK_EVENT or kind == c.CTRL_CLOSE_EVENT) {
        stop_requested.store(true, .release);
        return c.TRUE;
    }
    return c.FALSE;
}

fn help() void {
    std.debug.print(
        "Usage: zig-echo-server /p udp [/s port] [/w seconds] [/b bytes] [/k udp-depth]\n" ++
            "       [/cq capacity] [/memory bytes] [/rio-buffer bytes] [/q] [/stats]\n" ++
            "TCP modules are the next migration slice; this build implements the production RIO/IOCP UDP path.\n",
        .{},
    );
}

pub fn main(init: std.process.Init) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var error_buffer: [256]u8 = @splat(0);
    var options: types.Options = undefined;
    if (!options_mod.parseProcessArgs(init.minimal.args, arena_state.allocator(), &options, &error_buffer)) {
        std.debug.print("Invalid arguments: {s}\n", .{std.mem.sliceTo(&error_buffer, 0)});
        help();
        return @backingInt(types.ExitCode.usage);
    }
    if (options.help) {
        help();
        return 0;
    }
    if (options.protocol != .udp) {
        std.debug.print("This code drop currently enables the UDP RIO path; TCP/AcceptEx is intentionally not stubbed with a fallback.\n", .{});
        return @backingInt(types.ExitCode.usage);
    }

    stop_requested.store(false, .release);
    if (c.SetConsoleCtrlHandler(consoleHandler, c.TRUE) == c.FALSE) {
        win32.report("SetConsoleCtrlHandler", @intCast(c.GetLastError()));
        return @backingInt(types.ExitCode.internal);
    }
    defer _ = c.SetConsoleCtrlHandler(consoleHandler, c.FALSE);

    var winsock = win32.Winsock.init() catch {
        win32.report("WSAStartup", @intCast(c.WSAGetLastError()));
        return @backingInt(types.ExitCode.network);
    };
    defer winsock.deinit();

    var api = rio.Api.load() catch return @backingInt(types.ExitCode.network);
    return @backingInt(udp.run(&api, &options, &stop_requested));
}
