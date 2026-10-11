//! Drives the server's named fail-fast boundaries in a child process.
//!
//! Every mode must terminate the process with the internal exit code, leave stdout empty and put the
//! boundary's own stage name on stderr, which is exactly what a live run does when the same
//! invariant breaks.

const std = @import("std");
const server = @import("server");
const c = server.native.sdk.c;

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 2) return 1;
    const mode = argv[1];
    if (std.mem.eql(u8, mode, "notify_failure")) {
        server.native.guards.requireNotifySuccess(-1, "RIONotify(worker)");
    }
    if (std.mem.eql(u8, mode, "corrupt_cq")) {
        _ = server.native.guards.requireDequeueCount(c.RIO_CORRUPT_CQ, 256, "RIODequeueCompletion(worker)");
    }
    if (std.mem.eql(u8, mode, "invalid_transition")) {
        server.native.guards.requireTransition(false, "worker notification rearm transition");
    }
    if (std.mem.eql(u8, mode, "control_post_failure")) {
        server.native.guards.requireControlPost(c.FALSE, 5, "PostQueuedCompletionStatus(worker stop)");
    }
    return 1;
}
