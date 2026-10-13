//! Program entry point, console signal handling and the process exit code.

const std = @import("std");
const contract = @import("contract.zig");
const native = @import("native.zig");
const server = @import("server.zig");
const types = @import("types.zig");

const c = native.sdk.c;

fn consoleHandler(kind: c.DWORD) callconv(.winapi) c.BOOL {
    // CTRL_C_EVENT, CTRL_BREAK_EVENT and CTRL_CLOSE_EVENT all mean "stop the run now".
    if (kind == c.CTRL_C_EVENT or kind == c.CTRL_BREAK_EVENT or kind == c.CTRL_CLOSE_EVENT) {
        server.requestStop();
        return c.TRUE;
    }
    return c.FALSE;
}

pub fn main(init: std.process.Init) u8 {
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    var options: types.Options = undefined;
    // A malformed command line reports the diagnostic and the usage on stderr, leaving stdout empty.
    if (!contract.parseProcessArgs(init.minimal.args, &options, &error_buffer)) {
        var message_buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "Invalid arguments: {s}\n", .{std.mem.sliceTo(&error_buffer, 0)}) catch
            native.diagnostics.failFast("format argument error", c.ERROR_INSUFFICIENT_BUFFER);
        _ = native.diagnostics.writeStderr(message);
        _ = native.diagnostics.writeStderr(contract.usage);
        return @backingInt(types.ExitCode.usage);
    }
    // A valid help command line prints the usage on stdout and never starts the transport.
    if (options.help) {
        _ = native.diagnostics.writeStdout(contract.usage);
        return @backingInt(types.ExitCode.success);
    }
    server.clearControl();
    if (c.SetConsoleCtrlHandler(consoleHandler, c.TRUE) == c.FALSE) {
        const native_error = c.GetLastError();
        var message_buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "SetConsoleCtrlHandler failed: {d}\n", .{native_error}) catch
            native.diagnostics.failFast("format console registration error", c.ERROR_INSUFFICIENT_BUFFER);
        _ = native.diagnostics.writeStderr(message);
        return @backingInt(types.ExitCode.internal);
    }
    defer _ = c.SetConsoleCtrlHandler(consoleHandler, c.FALSE);
    return @backingInt(server.runServer(&options));
}
