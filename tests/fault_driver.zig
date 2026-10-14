//! Drives the server's named fail-fast boundaries in a child process.
//!
//! Every mode must terminate the process with the internal exit code, leave stdout empty and put the
//! boundary's own stage name on stderr, which is exactly what a live run does when the same
//! invariant breaks.

const std = @import("std");
const server = @import("server");
const c = server.native.sdk.c;
const acceptor = server.internal.acceptor;

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return 4;
    if (argv.len != 2) return 1;
    const mode = argv[1];
    if (std.mem.eql(u8, mode, "handoff_invalid")) {
        _ = acceptor.requireHandoffDisposition(false, false, true, false);
        return 1;
    }
    if (std.mem.eql(u8, mode, "handoff_positive")) {
        if (acceptor.requireHandoffDisposition(false, false, true, true) != .handoff or
            acceptor.requireHandoffDisposition(true, false, true, false) != .withdraw or
            acceptor.requireHandoffDisposition(false, true, true, false) != .withdraw or
            acceptor.requireHandoffDisposition(false, false, false, false) != .withdraw) return 1;
        return 0;
    }
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
    if (std.mem.eql(u8, mode, "partial_worker_start")) {
        // A real coordinator run in which the third of four workers never gets a thread. Reaching a
        // clean bounded exit proves what the exit code alone cannot: the two workers that did start
        // were joined before anything was released, and the worker whose storage exists without a
        // thread was released without touching uninitialised native state. A release that ran early
        // would corrupt or hang instead of returning an exit code.
        server.server.injectWorkerStartFailure(2);
        const options = server.types.Options{
            .protocol = .tcp,
            .port = 0,
            .worker_count = 4,
            .run_seconds = 1,
            .timeout_seconds = 1,
            .quiet = true,
            .stats = true,
        };
        return @backingInt(server.server.runServer(&options));
    }
    if (std.mem.eql(u8, mode, "worker_not_started")) {
        // The other half of a partially failed startup: a worker whose tcp.start never produced a
        // thread. Its storage still exists and is released by the cleanup scope, but it must not be
        // reported as an undrained worker -- there is no thread that could have failed to drain.
        // Returning from the guard at all is the assertion, so this boundary exits successfully.
        server.server.requireWorkerRelease(false, false);
        return 0;
    }
    if (std.mem.eql(u8, mode, "worker_undrained")) {
        // The coordinator's own guard, with the state it sees when a joined worker never retired its
        // operations.
        server.server.requireWorkerRelease(true, false);
    }
    if (std.mem.eql(u8, mode, "acceptor_ownership")) {
        // A real destroy() on an acceptor whose core still claims Windows owns an accept slot. There is
        // deliberately no native I/O here: the point is that the release boundary refuses to free the
        // table and the address records while that claim stands, so the process must die before the
        // free rather than after it.
        var states: [1]acceptor.State = undefined;
        var value: acceptor.Acceptor = .{};
        value.states = &states;
        value.core = acceptor.Core.init(&states);
        _ = value.core.transition(0, .idle, .posted);
        value.ready = true;
        acceptor.destroy(&value);
    }
    return 1;
}
