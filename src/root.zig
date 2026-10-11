//! Windows x64 RIO echo server core.
//!
//! The module tree mirrors the Rust server file for file: contract (command line and capacity
//! budgets) -> native (Winsock, RIO, AcceptEx and every resource owner) -> engine (the pure TCP
//! state machine) -> internal (acceptor, connection, UDP, worker, timer) -> server (dispatch and
//! shutdown) -> main (entry point).

const std = @import("std");

pub const contract = @import("contract.zig");
pub const engine = @import("engine.zig");
pub const internal = @import("internal.zig");
pub const native = @import("native.zig");
pub const server = @import("server.zig");
pub const types = @import("types.zig");

/// The names the state machines are reached by, re-exported so a test never has to spell out the
/// full path and so the shape of internal stays free to change.
pub const acceptor = internal.acceptor;
pub const connection = internal.connection;
pub const udp = internal.udp;
pub const worker = internal.worker;
pub const tcp = internal.worker.tcp;
pub const timer = internal.worker.timer;
pub const TcpEngine = engine.TcpEngine;
pub const Step = engine.Step;

test {
    _ = contract;
    _ = engine;
    _ = internal;
    _ = native;
    _ = server;
    _ = types;
}
