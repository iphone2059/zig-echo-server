const std = @import("std");
const server = @import("server");
const c = server.win32.c;

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 2) return 1;
    const mode = argv[1];
    if (std.mem.eql(u8, mode, "notify_failure")) {
        server.win32.failFast(mode, c.ERROR_INVALID_STATE);
    }
    if (std.mem.eql(u8, mode, "corrupt_cq")) {
        server.win32.failFast(mode, c.ERROR_INVALID_DATA);
    }
    if (std.mem.eql(u8, mode, "invalid_transition")) {
        var armed = true;
        if (!server.contract.notificationMarkRearmed(&armed)) server.win32.failFast(mode, c.ERROR_INVALID_STATE);
        return 0;
    }
    if (std.mem.eql(u8, mode, "control_post_failure")) {
        const port = c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1);
        if (port == null) return 4;
        _ = c.CloseHandle(port);
        if (c.PostQueuedCompletionStatus(port, 0, server.tcp_worker.stop_key, null) == c.FALSE)
            server.win32.failFast(mode, c.GetLastError());
        return 0;
    }
    return 1;
}
