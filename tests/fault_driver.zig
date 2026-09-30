const std = @import("std");
const server = @import("server");
const c = server.win32.c;

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 2) return 1;
    const mode = argv[1];
    if (std.mem.eql(u8, mode, "notify_failure")) {
        server.fault_guards.requireNotifySuccess(-1, "RIONotify(worker)");
    }
    if (std.mem.eql(u8, mode, "corrupt_cq")) {
        _ = server.fault_guards.requireDequeueCount(c.RIO_CORRUPT_CQ, 256, "RIODequeueCompletion(worker)");
    }
    if (std.mem.eql(u8, mode, "invalid_transition")) {
        server.fault_guards.requireTransition(false, "worker notification rearm transition");
    }
    if (std.mem.eql(u8, mode, "control_post_failure")) {
        server.fault_guards.requireControlPost(c.FALSE, 5, "PostQueuedCompletionStatus(worker stop)");
    }
    return 1;
}
