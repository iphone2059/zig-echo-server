//! Server state machines and runtimes: the connection record, the fixed-capacity timer heap, the
//! acceptor with its admission credits, the TCP worker runtime and the datagram engine.
//!
//! The pure TCP aggregate lives in engine.zig; this file owns everything that touches a native
//! handle. The nested namespaces are compile-time containers: none of them has a runtime instance,
//! a vtable or an allocation of its own.

const std = @import("std");
const contract = @import("contract.zig");
const engine = @import("engine.zig");
const native = @import("native.zig");
const types = @import("types.zig");

const c = native.sdk.c;

/// Per-connection TCP echo state machine, free of Win32 types so its transitions and the echo
/// progression are testable without a network. It is the direct counterpart of the connection
/// record handled by the C++ baseline's ces_engine_process_result.
pub const connection = struct {
    pub const State = enum(u8) {
        /// The slot is free; nothing owns it.
        idle,
        /// Adopted by the acceptor, waiting for the echo of the last receive.
        receiving,
        /// A receive completed and its bytes are being sent back.
        sending,
        /// The socket is gone; the slot waits for the operations still in flight.
        closing,
        /// The slot has been returned to the free list.
        released,
    };

    /// What the native layer must do for one connection. The engine adds the slot index.
    pub const Step = union(enum) {
        none,
        receive,
        send: struct { offset: u32, length: u32 },
        /// Close the socket now. The slot is not reusable yet: the operations that were in flight
        /// still have to complete, and the peer must see the connection go away immediately, which
        /// is what makes an idle connection time out.
        close,
        /// Close the socket if it is still open and return the slot to the free list.
        close_and_release,
    };

    pub const Connection = struct {
        index: u32 = 0,
        state: State = .idle,
        /// RIO operations posted and not yet completed. Never exceeds two: one receive or one send
        /// at a time.
        outstanding: u32 = 0,
        /// Bytes the last receive produced; the echo must return exactly these.
        echo_bytes: u32 = 0,
        /// Bytes of the echo already accepted by the socket.
        send_offset: u32 = 0,
        /// Absolute deadline of the operation in flight, when one is armed.
        deadline: u64 = 0,

        pub fn new(index: u32) Connection {
            return .{ .index = index };
        }

        pub fn isActive(self: *const Connection) bool {
            return self.state == .receiving or self.state == .sending or self.state == .closing;
        }

        pub fn isClosing(self: *const Connection) bool {
            return self.state == .closing;
        }

        pub fn isIdle(self: *const Connection) bool {
            return self.state == .idle;
        }

        /// Adopts the slot for a freshly accepted socket: the first receive is armed with the
        /// connection timeout.
        pub fn admit(self: *Connection, now: u64, timeout_milliseconds: u64) Step {
            self.state = .receiving;
            self.outstanding = 0;
            self.echo_bytes = 0;
            self.send_offset = 0;
            self.deadline = now +% timeout_milliseconds;
            return .receive;
        }

        /// A posted operation completed. status is the RIO status and bytes the transferred count.
        pub fn onCompletion(
            self: *Connection,
            operation: types.EngineOperation,
            status: i32,
            bytes: u32,
            now: u64,
            timeout_milliseconds: u64,
        ) Step {
            self.outstanding -|= 1;
            if (self.state == .closing) {
                // A socket closed with work in flight still has to be drained before the slot can be
                // handed to a new connection. The socket is already closed, so the release simply
                // closes it again (a no-op) and recycles the index.
                return if (self.outstanding == 0) self.release() else .none;
            }
            if (status != types.error_success) return self.close();
            switch (operation) {
                .receive => {
                    // A zero-byte receive is an orderly shutdown from the peer.
                    if (bytes == 0) return self.close();
                    self.echo_bytes = bytes;
                    self.send_offset = 0;
                    self.deadline = now +% timeout_milliseconds;
                    self.state = .sending;
                    return .{ .send = .{ .offset = 0, .length = bytes } };
                },
                .send => {
                    self.deadline = now +% timeout_milliseconds;
                    if (!contract.advanceOffsetU32(self.echo_bytes, bytes, &self.send_offset)) {
                        // A send that transferred nothing, or more than the echo, is a protocol
                        // failure: the echo cannot be completed.
                        return self.close();
                    }
                    if (self.send_offset < self.echo_bytes) {
                        return .{ .send = .{
                            .offset = self.send_offset,
                            .length = self.echo_bytes - self.send_offset,
                        } };
                    }
                    self.state = .receiving;
                    return .receive;
                },
            }
        }

        /// Closes the socket and, when nothing is in flight, releases the slot as well.
        pub fn close(self: *Connection) Step {
            if (self.state == .closing or self.state == .released or self.state == .idle) return .none;
            self.state = .closing;
            self.deadline = 0;
            return if (self.outstanding == 0) self.release() else .close;
        }

        fn release(self: *Connection) Step {
            self.state = .released;
            self.outstanding = 0;
            self.echo_bytes = 0;
            self.send_offset = 0;
            self.deadline = 0;
            return .close_and_release;
        }
    };
};

pub const worker = struct {
    /// A fixed-capacity indexed binary min-heap over absolute deadlines. It owns no memory: its
    /// nodes and the index-to-position map are allocated once when the worker starts.
    pub const timer = struct {
        pub const invalid_position: u32 = std.math.maxInt(u32);
        pub const infinite: u32 = std.math.maxInt(u32);

        pub const Node = struct {
            deadline: u64 = 0,
            index: u32 = 0,
        };

        pub const Heap = struct {
            nodes: []Node = &.{},
            positions: []u32 = &.{},
            len: u32 = 0,

            pub fn init(nodes: []Node, positions: []u32) !Heap {
                if (nodes.len == 0 or nodes.len != positions.len or nodes.len > std.math.maxInt(u32)) return error.InvalidCapacity;
                @memset(positions, invalid_position);
                return .{ .nodes = nodes, .positions = positions };
            }

            /// Ties break on the slot index, so equal deadlines expire in a deterministic order.
            fn less(a: Node, b: Node) bool {
                return a.deadline < b.deadline or (a.deadline == b.deadline and a.index < b.index);
            }

            fn swap(self: *Heap, a: u32, b: u32) void {
                std.mem.swap(Node, &self.nodes[a], &self.nodes[b]);
                self.positions[self.nodes[a].index] = a;
                self.positions[self.nodes[b].index] = b;
            }

            fn siftUp(self: *Heap, start: u32) void {
                var position = start;
                while (position != 0) {
                    const parent = (position - 1) / 2;
                    if (!less(self.nodes[position], self.nodes[parent])) break;
                    self.swap(position, parent);
                    position = parent;
                }
            }

            fn siftDown(self: *Heap, start: u32) void {
                var position = start;
                while (true) {
                    const left = position * 2 + 1;
                    if (left >= self.len) break;
                    var best = left;
                    const right = left + 1;
                    if (right < self.len and less(self.nodes[right], self.nodes[left])) best = right;
                    if (!less(self.nodes[best], self.nodes[position])) break;
                    self.swap(position, best);
                    position = best;
                }
            }

            pub fn insertOrUpdate(self: *Heap, index: u32, deadline: u64) bool {
                if (index >= self.positions.len) return false;
                const position = self.positions[index];
                if (position == invalid_position) {
                    if (self.len >= self.nodes.len) return false;
                    const slot = self.len;
                    self.len += 1;
                    self.nodes[slot] = .{ .deadline = deadline, .index = index };
                    self.positions[index] = slot;
                    self.siftUp(slot);
                    return true;
                }
                const previous = self.nodes[position].deadline;
                self.nodes[position].deadline = deadline;
                if (deadline < previous) self.siftUp(position) else self.siftDown(position);
                return true;
            }

            pub fn remove(self: *Heap, index: u32) bool {
                if (index >= self.positions.len) return false;
                const position = self.positions[index];
                if (position == invalid_position) return false;
                self.positions[index] = invalid_position;
                self.len -= 1;
                if (position == self.len) return true;
                self.nodes[position] = self.nodes[self.len];
                self.positions[self.nodes[position].index] = position;
                if (position != 0 and less(self.nodes[position], self.nodes[(position - 1) / 2])) {
                    self.siftUp(position);
                } else {
                    self.siftDown(position);
                }
                return true;
            }

            pub fn popExpired(self: *Heap, now: u64) ?u32 {
                if (self.len == 0 or self.nodes[0].deadline > now) return null;
                const index = self.nodes[0].index;
                _ = self.remove(index);
                return index;
            }

            pub fn waitMilliseconds(self: *const Heap, now: u64) u32 {
                if (self.len == 0) return infinite;
                const deadline = self.nodes[0].deadline;
                if (deadline <= now) return 0;
                return @intCast(@min(deadline - now, @as(u64, infinite - 1)));
            }

            pub fn isEmpty(self: *const Heap) bool {
                return self.len == 0;
            }
        };
    };

    /// The RIO request context of one TCP operation: the slot index and the operation, packed so the
    /// value is never zero and can be validated against the slot count without a side table. A slot
    /// is only recycled once every one of its completions has been dequeued, so a context can never
    /// alias a live request of a different connection.
    pub const context = struct {
        pub fn encode(index: u32, operation: types.EngineOperation) usize {
            // The index is stored one-based so the packed value is never the null context, which
            // leaves the low bit free for the operation.
            return (@as(usize, index + 1) << 1) | @as(usize, @backingInt(operation));
        }

        pub const Decoded = struct { index: u32, operation: types.EngineOperation };

        pub fn decode(value: usize, slot_count: u32) ?Decoded {
            if (value == 0) return null;
            const stored = value >> 1;
            if (stored == 0 or stored - 1 >= slot_count) return null;
            return .{
                .index = @intCast(stored - 1),
                .operation = if (value & 1 == 1) .send else .receive,
            };
        }
    };

    pub const ProviderRequest = struct { operation: ?types.EngineOperation = null, length: u32 = 0 };

    /// The TCP worker runtime: the loop that translates the pure engine's steps into RIO calls and
    /// back. Every native failure is either contained to one connection or is a process-level fault;
    /// nothing in between is silently ignored.
    pub const tcp = struct {
        pub const Worker = TcpWorker;

        pub const InitError = error{
            Port,
            ReadyEvent,
            Capacity,
            Arena,
            SlotOwners,
            RequestQueues,
            Steps,
            Engine,
            CompletionQueue,
        };

        fn failFast(stage: []const u8, native_error: u32) noreturn {
            native.diagnostics.failFast(stage, native_error);
        }

        /// Whether a handoff that reached this worker has to be withdrawn instead of adopted.
        ///
        /// Only the worker's own stop withdraws it: beginStop closes admission and closes the sockets
        /// it is already serving, so a socket arriving after that point cannot be adopted and may in
        /// fact already be closed. The handoff is acknowledged so the acceptor recycles the slot, and
        /// nothing is reported, because a stop is not a network fault. A worker that has merely
        /// reached the admission barrier is still running and still adopts, so testing that flag here
        /// would turn a genuine request-queue failure into a silent withdrawal.
        pub fn withdrawsHandoff(stopping: bool) bool {
            return stopping;
        }

        fn closeSocket(wrk: *Worker, index: u32) void {
            if (index < wrk.connection_sockets.len) wrk.connection_sockets[index].deinit();
            if (index < wrk.request_queues.len) wrk.request_queues[index] = c.RIO_INVALID_RQ;
        }

        fn releaseSlot(wrk: *Worker, index: u32) void {
            if (index >= wrk.provider_requests.len or index >= wrk.connection_sockets.len or index >= wrk.request_queues.len) {
                failFast("TCP connection release index", c.ERROR_INVALID_DATA);
            }
            if (wrk.provider_requests[index].operation != null) {
                failFast("TCP connection release precondition", c.ERROR_IO_INCOMPLETE);
            }
            closeSocket(wrk, index);
            wrk.credits.?.release();
        }

        fn arm(wrk: *Worker) void {
            if (wrk.completion_queue.armed) failFast("duplicate worker RIONotify", c.ERROR_INVALID_STATE);
            wrk.notification_overlapped = std.mem.zeroes(c.OVERLAPPED);
            native.guards.requireNotifySuccess(wrk.api.?.notify(wrk.completion_queue.value), "RIONotify(worker)");
            native.guards.requireTransition(contract.notificationMarkRearmed(&wrk.completion_queue.armed), "notification rearm transition");
            wrk.engine_value.notification_armed = wrk.completion_queue.armed;
            wrk.notification_arms +%= 1;
        }

        /// The queue is armed only while work is in flight, so an idle worker never leaves a
        /// notification the provider still owns.
        fn maybeArm(wrk: *Worker) void {
            if (wrk.completion_queue.armed) return;
            if (wrk.engine_value.outstanding() == 0) return;
            arm(wrk);
        }

        fn postReceive(wrk: *Worker, index: u32, deadline: u64) ?types.Failure {
            _ = deadline;
            if (index >= wrk.provider_requests.len or wrk.provider_requests[index].operation != null) failFast("worker post ownership", c.ERROR_INVALID_DATA);
            const stride = wrk.stride();
            var buffer = wrk.arena.view(index, 0, stride) orelse failFast("worker receive window", c.ERROR_INVALID_DATA);
            const rq = wrk.request_queues[index];
            if (rq == c.RIO_INVALID_RQ) {
                failFast("worker receive queue", c.ERROR_INVALID_STATE);
            }
            const submitted_length = buffer.Length;
            if (!wrk.api.?.receive(rq, &buffer, 0, @ptrFromInt(context.encode(index, .receive)))) {
                return native.winsockFailure("RIOReceive");
            }
            wrk.provider_requests[index] = .{ .operation = .receive, .length = submitted_length };
            wrk.provider_outstanding += 1;
            return null;
        }

        fn postSend(wrk: *Worker, index: u32, offset: u32, length: u32, deadline: u64) ?types.Failure {
            _ = deadline;
            if (index >= wrk.provider_requests.len or wrk.provider_requests[index].operation != null) failFast("worker post ownership", c.ERROR_INVALID_DATA);
            if (length == 0) failFast("worker send window", c.ERROR_INVALID_DATA);
            var buffer = wrk.arena.view(index, offset, length) orelse failFast("worker send window", c.ERROR_INVALID_DATA);
            const rq = wrk.request_queues[index];
            if (rq == c.RIO_INVALID_RQ) {
                failFast("worker send queue", c.ERROR_INVALID_STATE);
            }
            const submitted_length = buffer.Length;
            if (!wrk.api.?.send(rq, &buffer, 0, @ptrFromInt(context.encode(index, .send)))) {
                return native.winsockFailure("RIOSend");
            }
            wrk.provider_requests[index] = .{ .operation = .send, .length = submitted_length };
            wrk.provider_outstanding += 1;
            return null;
        }

        /// Carries out one engine step. A failure means the post was refused, which the engine turns
        /// into a connection failure rather than a process failure.
        fn execute(wrk: *Worker, step: engine.Step) ?types.Failure {
            switch (step) {
                .receive => |value| return postReceive(wrk, value.index, value.deadline),
                .send => |value| return postSend(wrk, value.index, value.offset, value.length, value.deadline),
                .close => |index| {
                    closeSocket(wrk, index);
                    return null;
                },
                .release => |index| {
                    releaseSlot(wrk, index);
                    return null;
                },
            }
        }

        fn executeAll(wrk: *Worker, steps: []const engine.Step) void {
            if (wrk.engine_value.fatal) {
                if (wrk.engine_value.failure) |failure| failFast(failure.stage, @bitCast(failure.code));
                failFast("worker engine invariant", c.ERROR_INVALID_DATA);
            }
            for (steps) |step| {
                const failure = execute(wrk, step) orelse {
                    maybeArm(wrk);
                    continue;
                };
                native.diagnostics.reportFailure(failure);
                var failure_steps: [1]engine.Step = undefined;
                const next = wrk.engine_value.onEvent(.{ .post_rejected = .{ .index = step.index(), .failure = failure } }, &failure_steps);
                if (wrk.engine_value.fatal) failFast("worker refused post ownership", c.ERROR_INVALID_DATA);
                for (next) |value| {
                    if (execute(wrk, value)) |unexpected| failFast(unexpected.stage, @bitCast(unexpected.code));
                }
            }
        }

        fn drain(wrk: *Worker, batch_budget: u32, record_budget: u32) void {
            var results: [types.completion_batch_size]c.RIORESULT = undefined;
            var batches: u32 = 0;
            var remaining = record_budget;
            while (batches < batch_budget and remaining != 0) : (batches += 1) {
                const requested = @min(types.completion_batch_size, remaining);
                const count = native.guards.requireDequeueCount(
                    wrk.api.?.dequeue(wrk.completion_queue.value, &results, requested),
                    requested,
                    "RIODequeueCompletion(worker)",
                );
                if (count == 0) return;
                remaining -= count;
                for (results[0..count]) |result| processResult(wrk, result);
            }
        }

        fn processResult(wrk: *Worker, result: c.RIORESULT) void {
            const raw = result.RequestContext orelse failFast("worker null RequestContext", c.ERROR_INVALID_DATA);
            const decoded = context.decode(@intFromPtr(raw), wrk.engine_value.slotCount()) orelse
                failFast("worker RIO RequestContext", c.ERROR_INVALID_DATA);
            if (decoded.index >= wrk.provider_requests.len or wrk.provider_outstanding == 0 or
                wrk.provider_requests[decoded.index].operation == null or wrk.provider_requests[decoded.index].operation.? != decoded.operation or
                wrk.provider_outstanding != wrk.engine_value.outstanding())
            {
                failFast("worker completion invariant", c.ERROR_INVALID_DATA);
            }
            if (result.BytesTransferred > wrk.provider_requests[decoded.index].length) failFast("worker completion payload extent", c.ERROR_INVALID_DATA);
            wrk.provider_requests[decoded.index] = .{};
            wrk.provider_outstanding -= 1;
            const now = native.nowMilliseconds();
            const decisions = wrk.engine_value.onEvent(.{ .completion = .{ .value = .{ .index = decoded.index, .operation = decoded.operation, .status = result.Status, .bytes = result.BytesTransferred }, .now = now } }, wrk.steps);
            if (wrk.engine_value.fatal) {
                failFast("worker engine invariant", c.ERROR_INVALID_DATA);
            }
            executeAll(wrk, decisions);
        }

        fn stopNow(wrk: *Worker) void {
            if (wrk.drain_started == null) wrk.drain_started = native.nowMilliseconds();
            const closing = wrk.engine_value.onEvent(.{ .stop = native.nowMilliseconds() }, wrk.steps);
            executeAll(wrk, closing);
            maybeArm(wrk);
            if (wrk.engine_value.fatal) wrk.failed.?.store(true, .release);
        }

        fn acknowledge(operation: *acceptor.Operation) void {
            if (!native.rio.postCompletion(operation.acceptor_port, @intFromPtr(operation), null)) {
                failFast("PostQueuedCompletionStatus(accept ack)", c.GetLastError());
            }
        }

        /// Adopts one accepted socket into a free slot. A stopping worker or a full table withdraws
        /// the socket, returns its credit and acknowledges the handoff so the acceptor can recycle
        /// the operation instead of waiting forever.
        pub fn takeSocket(wrk: *Worker, operation: *acceptor.Operation) void {
            if (withdrawsHandoff(wrk.engine_value.stopping)) {
                // The socket is withdrawn before it is taken, which is the order the reference uses:
                // a stopping worker has already closed admission, so the accepted socket may have
                // been closed under this handoff and must not be handed to RIOCreateRequestQueue.
                // Reporting that close as a failure would turn an ordinary shutdown into a network
                // fault, which is exactly what this guard prevents.
                wrk.credits.?.release();
                operation.socket_owner.deinit();
                operation.socket = c.INVALID_SOCKET;
                acknowledge(operation);
                return;
            }
            var owner = native.socket.Socket{ .value = operation.socket_owner.take() };
            operation.socket = c.INVALID_SOCKET;
            const socket_value = owner.get();
            const index = wrk.engine_value.takeSlot() orelse {
                wrk.credits.?.release();
                owner.deinit();
                acknowledge(operation);
                if (!wrk.engine_value.stopping) failFast("admission credit/free pool mismatch", c.ERROR_INVALID_STATE);
                return;
            };
            wrk.connection_sockets[index].reset(owner.take());
            const rq = wrk.api.?.createRq(
                socket_value,
                1,
                1,
                1,
                1,
                wrk.completion_queue.value,
                wrk.completion_queue.value,
                null,
            );
            if (rq == c.RIO_INVALID_RQ) {
                wrk.engine_value.statistics.network_errors +%= 1;
                native.diagnostics.report("RIOCreateRequestQueue(TCP)", @bitCast(c.WSAGetLastError()));
                wrk.engine_value.returnSlot(index);
                wrk.credits.?.release();
                closeSocket(wrk, index);
                acknowledge(operation);
                return;
            }
            wrk.request_queues[index] = rq;
            const admit_step = wrk.engine_value.admit(index, native.nowMilliseconds()) orelse {
                wrk.engine_value.returnSlot(index);
                wrk.credits.?.release();
                closeSocket(wrk, index);
                acknowledge(operation);
                return;
            };
            // Adoption consumes the reservation the acceptor already took; the credit comes back
            // only when this connection is released.
            executeAll(wrk, &[_]engine.Step{admit_step});
            acknowledge(operation);
        }

        pub fn initialize(
            wrk: *Worker,
            api: *const native.rio.Api,
            options: *const types.Options,
            failed: *std.atomic.Value(bool),
            worker_index: u32,
            slot_count: u32,
            credits: *acceptor.AdmissionCredits,
        ) InitError!void {
            switch (initializeResult(wrk, api, options, failed, worker_index, slot_count, credits)) {
                .value => {},
                .failure => |failure| {
                    native.diagnostics.reportFailure(failure);
                    return error.Engine;
                },
            }
        }

        pub fn initializeResult(
            wrk: *Worker,
            api: *const native.rio.Api,
            options: *const types.Options,
            failed: *std.atomic.Value(bool),
            worker_index: u32,
            slot_count: u32,
            credits: *acceptor.AdmissionCredits,
        ) native.Result(void) {
            const allocator = std.heap.page_allocator;
            wrk.* = .{};
            var initialized = false;
            defer if (!initialized) destroy(wrk);
            wrk.api = api;
            wrk.options = options;
            wrk.failed = failed;
            wrk.worker_index = worker_index;
            wrk.credits = credits;
            if (slot_count == 0) return .{ .failure = .{ .stage = "worker registered arena capacity", .code = types.error_not_enough_memory, .domain = .allocation } };

            wrk.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
            if (wrk.port.value == null or wrk.port.value == c.INVALID_HANDLE_VALUE) {
                return .{ .failure = native.win32Failure("CreateIoCompletionPort(worker)") };
            }
            wrk.ready_event.reset(c.CreateEventW(null, c.TRUE, c.FALSE, null));
            if (wrk.ready_event.value == null) {
                return .{ .failure = native.win32Failure("CreateEventW(worker ready)") };
            }
            const stride = native.arena.tcpStride(options.rio_buffer_bytes);
            wrk.arena = switch (native.arena.Arena.createResult(api, slot_count, stride)) {
                .value => |value| value,
                .failure => |failure| {
                    var diagnostic = failure;
                    diagnostic.stage = switch (failure.domain) {
                        .winsock => "RIORegisterBuffer(worker slots)",
                        .allocation => "worker registration owners",
                        .win32 => "VirtualAlloc(worker arena)",
                        .invariant => failure.stage,
                    };
                    return .{ .failure = diagnostic };
                },
            };
            wrk.connection_sockets = allocator.alloc(native.socket.Socket, slot_count) catch {
                return .{ .failure = .{ .stage = "worker allocation", .code = types.error_not_enough_memory, .domain = .allocation } };
            };
            for (wrk.connection_sockets) |*owner| owner.* = .{};
            wrk.request_queues = allocator.alloc(c.RIO_RQ, slot_count) catch {
                return .{ .failure = .{ .stage = "worker allocation", .code = types.error_not_enough_memory, .domain = .allocation } };
            };
            @memset(wrk.request_queues, c.RIO_INVALID_RQ);
            wrk.provider_requests = allocator.alloc(ProviderRequest, slot_count) catch
                return .{ .failure = .{ .stage = "worker allocation", .code = types.error_not_enough_memory, .domain = .allocation } };
            @memset(wrk.provider_requests, .{});
            wrk.steps = allocator.alloc(engine.Step, engine.stepCapacity(slot_count)) catch {
                return .{ .failure = .{ .stage = "worker allocation", .code = types.error_not_enough_memory, .domain = .allocation } };
            };
            wrk.engine_value = engine.TcpEngine.init(slot_count, @as(u64, options.timeout_seconds) * 1000) catch |failure| {
                return .{ .failure = switch (failure) {
                    error.TimerHeap => types.Failure.invariant("worker engine timer heap"),
                    else => .{ .stage = "worker allocation", .code = types.error_not_enough_memory, .domain = .allocation },
                } };
            };
            var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
            notification.Type = c.RIO_IOCP_COMPLETION;
            notification.Iocp.IocpHandle = wrk.port.get();
            notification.Iocp.CompletionKey = @ptrCast(wrk);
            notification.Iocp.Overlapped = @ptrCast(&wrk.notification_overlapped);
            wrk.completion_queue.reset(api, api.createCq(slot_count * 2, &notification));
            if (!wrk.completion_queue.valid()) {
                return .{ .failure = native.winsockFailure("RIOCreateCompletionQueue(worker)") };
            }
            initialized = true;
            return .{ .value = {} };
        }

        fn threadEntry(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
            const wrk: *Worker = @ptrCast(@alignCast(parameter.?));
            return workerThread(wrk);
        }

        pub fn start(wrk: *Worker) bool {
            wrk.thread.reset(c.CreateThread(null, 0, threadEntry, @ptrCast(wrk), 0, null));
            if (wrk.thread.value == null) {
                native.diagnostics.report("CreateThread(worker)", c.GetLastError());
                return false;
            }
            if (c.WaitForSingleObject(wrk.ready_event.get(), types.infinite) != types.wait_object_0 or !wrk.ready) {
                native.diagnostics.report("worker startup readiness", c.ERROR_INVALID_STATE);
                return false;
            }
            return true;
        }

        pub fn postHandoff(wrk: *Worker, operation: *acceptor.Operation) void {
            if (!native.rio.postCompletion(wrk.port.get(), @intFromPtr(operation), null)) {
                failFast("PostQueuedCompletionStatus(accept handoff)", c.GetLastError());
            }
        }

        pub fn postAdmissionClosed(wrk: *Worker) void {
            if (!native.rio.postCompletion(wrk.port.get(), types.admission_closed_key, null)) {
                failFast("PostQueuedCompletionStatus(admission closed)", c.GetLastError());
            }
        }

        pub fn postStop(wrk: *Worker) void {
            if (native.rio.postCompletion(wrk.port.get(), types.stop_key, null)) return;
            native.guards.requireControlPost(c.FALSE, c.GetLastError(), "PostQueuedCompletionStatus(worker stop)");
        }

        pub fn join(wrk: *Worker) void {
            if (wrk.thread.value != null and c.WaitForSingleObject(wrk.thread.value, types.infinite) != types.wait_object_0) {
                failFast("WaitForSingleObject(worker)", c.GetLastError());
            }
        }

        pub fn requireRelease(wrk: *const Worker) void {
            if (wrk.provider_outstanding != 0 or wrk.engine_value.outstanding() != 0) failFast("TCP worker release precondition", c.ERROR_IO_INCOMPLETE);
            for (wrk.provider_requests) |request| {
                if (request.operation != null) failFast("TCP worker release precondition", c.ERROR_IO_INCOMPLETE);
            }
            if (wrk.ready and (!wrk.engine_value.stopping or !wrk.engine_value.admission_closed or
                !wrk.engine_value.mayExit() or wrk.engine_value.freeCount() != wrk.engine_value.slotCount() or
                (wrk.credits != null and !wrk.credits.?.isFull())))
            {
                failFast("TCP worker release precondition", c.ERROR_IO_INCOMPLETE);
            }
            const snapshot = types.NotifySnapshot{ .worker = wrk.worker_index, .arms = wrk.notification_arms, .deliveries = wrk.notification_deliveries, .timeout_wakeups = wrk.timeout_wakeups };
            if (wrk.ready and !snapshot.valid()) failFast("worker notification accounting", c.ERROR_INVALID_STATE);
        }

        /// Releases every native object in the order the design fixes: sockets, completion queue,
        /// registrations, the single page owner, the host arrays, then the port.
        pub fn destroy(wrk: *Worker) void {
            const allocator = std.heap.page_allocator;
            join(wrk);
            requireRelease(wrk);
            wrk.thread.deinit();
            wrk.completion_queue.deinit();
            wrk.arena.deinit();
            for (wrk.connection_sockets) |*owner| owner.deinit();
            if (wrk.connection_sockets.len != 0) allocator.free(wrk.connection_sockets);
            if (wrk.request_queues.len != 0) allocator.free(wrk.request_queues);
            if (wrk.provider_requests.len != 0) allocator.free(wrk.provider_requests);
            if (wrk.steps.len != 0) allocator.free(wrk.steps);
            wrk.connection_sockets = &.{};
            wrk.request_queues = &.{};
            wrk.provider_requests = &.{};
            wrk.steps = &.{};
            wrk.engine_value.deinit();
            wrk.ready_event.deinit();
            wrk.port.deinit();
            wrk.ready = false;
        }

        fn workerThread(wrk: *Worker) c.DWORD {
            wrk.engine_value.phase = .running;
            maybeArm(wrk);
            wrk.ready = true;
            if (c.SetEvent(wrk.ready_event.get()) == c.FALSE) failFast("SetEvent(worker ready)", c.GetLastError());
            var expired_packets: u32 = 0;
            const expired_packet_budget = wrk.engine_value.slotCount() + contract.acceptOperationCount(types.maximum_workers) + 2;

            while (true) {
                const now = native.nowMilliseconds();
                const drain_due = if (wrk.drain_started) |started|
                    now - started >= types.drain_milliseconds and wrk.provider_outstanding != 0
                else
                    false;
                const wait = if (drain_due or wrk.engine_value.waitingMilliseconds(now) == 0) 0 else if (wrk.engine_value.stopping)
                    @min(wrk.engine_value.waitingMilliseconds(now), 100)
                else
                    wrk.engine_value.waitingMilliseconds(now);
                const packet = native.rio.getQueuedCompletionStatus(wrk.port.get(), wait);
                const queued_record = packet.ok or packet.overlapped != null or packet.key != 0;
                if (packet.overlapped == &wrk.notification_overlapped) {
                    if (!packet.ok) failFast("GetQueuedCompletionStatus(worker notification)", packet.native_error);
                    if (!contract.notificationPacketMatches(packet.key, @intFromPtr(packet.overlapped.?), @intFromPtr(wrk), @intFromPtr(&wrk.notification_overlapped))) {
                        failFast("worker RIO notification key", c.ERROR_INVALID_DATA);
                    }
                    native.guards.requireTransition(contract.notificationMarkDelivered(&wrk.completion_queue.armed), "notification delivery transition");
                    wrk.engine_value.notification_armed = wrk.completion_queue.armed;
                    wrk.notification_deliveries +%= 1;
                    drain(wrk, types.completion_drain_batches, std.math.maxInt(u32));
                    maybeArm(wrk);
                } else if (packet.overlapped == null and packet.key == types.stop_key) {
                    stopNow(wrk);
                } else if (packet.overlapped == null and packet.key == types.admission_closed_key) {
                    _ = wrk.engine_value.onEvent(.admission_closed, wrk.steps);
                } else if (packet.overlapped == null and packet.key > types.admission_closed_key) {
                    const operation: *acceptor.Operation = @ptrFromInt(packet.key);
                    takeSocket(wrk, operation);
                } else if (!packet.ok and packet.native_error != c.WAIT_TIMEOUT) {
                    native.diagnostics.report("GetQueuedCompletionStatus(worker)", packet.native_error);
                    wrk.engine_value.statistics.network_errors +%= 1;
                    wrk.failed.?.store(true, .release);
                    stopNow(wrk);
                } else if (!(!packet.ok and packet.native_error == c.WAIT_TIMEOUT and packet.overlapped == null)) {
                    failFast("unexpected worker IOCP packet", c.ERROR_INVALID_DATA);
                }

                if (!packet.ok and packet.native_error == c.WAIT_TIMEOUT and !wrk.engine_value.stopping and
                    wrk.engine_value.outstanding() != 0 and !wrk.completion_queue.armed)
                {
                    wrk.timeout_wakeups +%= 1;
                }
                if (wrk.engine_value.stopping and wrk.engine_value.admission_closed and wrk.engine_value.activeCount() == 0) break;
                const after_packet = native.nowMilliseconds();
                const still_draining = if (wrk.drain_started) |started|
                    after_packet - started >= types.drain_milliseconds and wrk.provider_outstanding != 0
                else
                    false;
                if (still_draining or wrk.engine_value.waitingMilliseconds(after_packet) == 0) {
                    // Include handoffs plus both shutdown controls in the bounded zero-wait pass:
                    // they may precede a queued RIO notification even on a worker with one slot.
                    if (queued_record and expired_packets < expired_packet_budget) {
                        expired_packets += 1;
                        continue;
                    }
                    // A pending RIONotify does not prove the CQ is empty. The final pass retires
                    // at most one record per slot in total, even with one-record short dequeues.
                    // Direct CQ polling leaves the notification ownership and ledger untouched.
                    drain(wrk, wrk.engine_value.slotCount(), wrk.engine_value.slotCount());
                    maybeArm(wrk);
                    const drain_expired = if (wrk.drain_started) |started|
                        after_packet - started >= types.drain_milliseconds and wrk.provider_outstanding != 0
                    else
                        false;
                    if (drain_expired) failFast("TCP worker drain deadline", c.ERROR_TIMEOUT);
                    expired_packets = 0;
                } else expired_packets = 0;
                const expired = wrk.engine_value.onEvent(.{ .timeout = after_packet }, wrk.steps);
                executeAll(wrk, expired);
                if (wrk.engine_value.fatal) {
                    if (wrk.engine_value.failure) |failure| failFast(failure.stage, @bitCast(failure.code));
                    failFast("worker engine invariant", c.ERROR_INVALID_DATA);
                }
                if (wrk.engine_value.stopping and wrk.engine_value.admission_closed and wrk.engine_value.activeCount() == 0) break;
            }

            // The coordinator joins every worker before checking any release precondition.
            wrk.engine_value.phase = .stopped;
            return if (wrk.failed.?.load(.acquire)) 1 else 0;
        }
    };
};

/// The acceptor's admission accounting.
///
/// A credit is taken the moment a socket is selected for a worker and is only given back when the
/// connection is released, so the acceptor never publishes more sockets than the worker can hold --
/// including the ones that are still in transit through the completion port.
pub const acceptor = struct {
    /// The shared admission accounting.
    ///
    /// Exactly one counter crosses the thread boundary: the acceptor reserves while it selects a
    /// worker, and a worker gives the credit back from its own thread when the connection ends or a
    /// handoff is withdrawn. A plain integer here would be a data race that surfaces as an
    /// over-admitted worker or a lost credit, neither of which the completion counters would show.
    ///
    /// The counter holds the credits that are still free. A reservation is consumed the moment the
    /// socket is handed over and only returned when the connection is released, so the acceptor can
    /// never overbook a worker -- including with sockets still in transit through the completion port.
    pub const AdmissionCredits = struct {
        available: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        /// Immutable for the whole run; only the atomic counter moves.
        capacity: u32 = 0,

        pub fn init(capacity: u32) AdmissionCredits {
            return .{ .available = std.atomic.Value(u32).init(capacity), .capacity = capacity };
        }

        /// Takes one credit if any is left. The compare-exchange loop is what makes the reservation
        /// exact against a release happening on a worker thread at the same moment.
        pub fn tryReserve(self: *AdmissionCredits) bool {
            var observed = self.available.load(.acquire);
            while (true) {
                if (observed == 0) return false;
                if (self.available.cmpxchgWeak(observed, observed - 1, .acquire, .monotonic)) |actual| {
                    observed = actual;
                } else return true;
            }
        }

        /// Returns one credit. Returning more than the capacity means the accounting lost a credit,
        /// which is an internal invariant failure rather than a counter to clamp.
        pub fn release(self: *AdmissionCredits) void {
            const previous = self.available.fetchAdd(1, .release);
            if (previous >= self.capacity) {
                native.diagnostics.failFast("worker admission credit", c.ERROR_INVALID_STATE);
            }
        }

        /// True when every credit has been returned, which is the terminal condition the shutdown
        /// barrier waits for.
        pub fn isFull(self: *const AdmissionCredits) bool {
            return self.get() == self.capacity;
        }

        /// Credits not handed out. Admission never releases more than it reserved, so this never
        /// exceeds the capacity; a test that observes it can tell a returned reservation from a
        /// double release.
        pub fn get(self: *const AdmissionCredits) u32 {
            return self.available.load(.acquire);
        }
    };

    /// The bounded accept window: two operations per worker, at least eight and at most 128.
    pub const operation_count = contract.acceptOperationCount;

    pub const State = enum(u8) {
        idle = 0,
        posted = 1,
        /// The socket was handed to a worker and is waiting to be acknowledged.
        transit = 2,
        /// The synchronous reset retries were exhausted, so this slot yielded to a queued repost.
        deferred = 3,
    };

    /// What the shutdown path must do with one accept operation.
    /// What one AcceptEx completion means, and what the acceptor thread must do next.
    ///
    /// This is the reference's AcceptAction. A completion is decided purely, and the decision names
    /// the slot and, for a handoff, the worker the rotation selected.
    pub const AcceptAction = union(enum) {
        /// AcceptEx completed: transfer the socket and publish the handoff to this worker.
        handoff: struct { index: u32, worker: u32 },
        /// Post AcceptEx on this slot.
        repost: u32,
        /// Admission is broken and the acceptor stops. The field is code rather than error because
        /// error is a Zig keyword; it carries the same native status the reference calls error.
        fail: struct { index: u32, code: i32 },
        /// Nothing to do; the slot stays idle.
        none,
    };

    pub const Event = union(enum) {
        completion: struct { index: u32, completed: bool, code: i32 },
        acknowledged: u32,
        stop,
    };

    pub const Lifecycle = struct { stopping: bool, live: u32, posted: u32 };

    /// What the acceptor does with one slot when it stops. This is a shutdown disposition, not the
    /// decision a completion produces; that one is AcceptAction above.
    pub const SlotDisposition = enum(u8) { none, close_posted, wait_ack };

    /// Whether a failed AcceptEx completion is a fault of this run rather than a consequence of
    /// shutting it down.
    ///
    /// The acceptor is the only member that closes an accept slot, and it closes them from beginStop,
    /// so under stopping this failure is the cancellation the stop itself requested. A run whose
    /// global failure flag is already set is failing for a reason that was reported when it was set,
    /// so it accumulates no further ledger entries either. Both references test exactly these two
    /// conditions before counting, while the acceptor loop unposts on the same flag, so a real
    /// connection-level fault during healthy admission is still counted.
    pub fn acceptorCountsFailure(stopping: bool, failed: bool) bool {
        return !stopping and !failed;
    }

    /// What the handoff path does when a successful AcceptEx completion is taken off the port.
    pub const Disposition = enum(u8) {
        /// The stop owns this slot's socket: retire the slot instead of configuring a closed socket.
        withdraw,
        /// A healthy admission path lost its accepted socket, so ownership is corrupt.
        fatal,
        /// Admission is still healthy and both handles are usable.
        handoff,
    };

    /// Decides the handoff guard purely, without a listener and without an operation record.
    ///
    /// Stop, global failure and listener retirement withdraw admission. Only an accepted socket
    /// missing while admission is otherwise healthy breaks the ownership invariant.
    pub fn handoffDisposition(stopping: bool, failed: bool, listener_valid: bool, accepted_valid: bool) Disposition {
        if (stopping or failed or !listener_valid) return .withdraw;
        if (!accepted_valid) return .fatal;
        return .handoff;
    }

    /// Runtime boundary shared by production and the process fault driver. The pure decision above
    /// does not report errors or release resources.
    pub fn requireHandoffDisposition(stopping: bool, failed: bool, listener_valid: bool, accepted_valid: bool) Disposition {
        const disposition = handoffDisposition(stopping, failed, listener_valid, accepted_valid);
        if (disposition == .fatal) failFast("AcceptEx handoff invariant", c.WSAENOTSOCK);
        return disposition;
    }

    /// Completion statuses an accept can recover from instead of failing the listener. A peer that
    /// resets or is deleted between the accept and the completion is a connection-level event.
    pub fn acceptErrorIsRecoverable(status: i32) bool {
        // ERROR_NETNAME_DELETED, WSAECONNRESET and WSAECONNABORTED.
        return status == 64 or status == types.wsa_econnreset or status == types.wsa_econnaborted;
    }

    /// Round-robin over the workers that still have a credit. Scanning instead of taking the next
    /// index is what keeps a saturated worker from being handed a socket it would have to refuse.
    pub fn selectWorker(credits: []AdmissionCredits, rotation: *u32, worker_count: u32) ?u32 {
        if (worker_count == 0 or credits.len < worker_count) return null;
        var step: u32 = 0;
        while (step < worker_count) : (step += 1) {
            const index = (rotation.* + step) % worker_count;
            // The reservation happens here, so a returned worker is already charged for the socket
            // the acceptor is about to publish.
            if (credits[index].tryReserve()) {
                rotation.* = (index + 1) % worker_count;
                return index;
            }
        }
        return null;
    }

    /// The bounded number of synchronous attempts one operation makes before it yields to a queued
    /// repost, matching the reference.
    pub const synchronous_attempts: u32 = 4;

    /// The pure accept state: which slot is posted, who is waiting, and the admission tallies.
    ///
    /// It owns no native object, so every transition, the worker rotation and the refusal counting
    /// are testable without a listener or a completion port.
    pub const Core = struct {
        states: []State = &.{},
        /// Round-robin cursor over the workers.
        rotation: u32 = 0,
        stopping: bool = false,
        /// The workers the rotation walks, and the round-robin cursor over them.
        worker_count: u32 = 0,
        /// Connects refused because every worker's credits were already committed.
        rejected: u64 = 0,
        /// Refused AcceptEx attempts and accept-socket failures, merged into the run's ledger: a
        /// reset storm the listener recovers from still has to be visible in network_errors.
        network_errors: u64 = 0,

        pub fn init(states: []State) Core {
            @memset(states, .idle);
            return .{ .states = states };
        }

        pub fn onEvent(self: *Core, event: Event) AcceptAction {
            return switch (event) {
                .completion => |value| self.onCompletion(value.index, value.completed, value.code),
                .acknowledged => |index| self.onAck(index),
                .stop => {
                    self.stop();
                    return .none;
                },
            };
        }

        pub fn lifecycle(self: *const Core) Lifecycle {
            return .{ .stopping = self.stopping, .live = self.liveCount(), .posted = self.postedCount() };
        }

        pub fn count(self: *const Core) u32 {
            return @intCast(self.states.len);
        }

        pub fn state(self: *const Core, index: u32) ?State {
            return if (index < self.states.len) self.states[index] else null;
        }

        /// The only legal accept transitions: idle -> posted -> transit -> idle, where a posted or
        /// idle slot may also yield to a deferred repost.
        pub fn transition(self: *Core, index: u32, expected: State, desired: State) bool {
            if (self.state(index) != expected) return false;
            const legal = (expected == .idle and (desired == .posted or desired == .deferred)) or
                (expected == .posted and (desired == .transit or desired == .idle or desired == .deferred)) or
                (expected == .transit and desired == .idle) or
                (expected == .deferred and desired == .idle);
            if (!legal) return false;
            self.states[index] = desired;
            return true;
        }

        pub fn dispositionFor(self: *const Core, index: u32) SlotDisposition {
            return switch (self.state(index) orelse .idle) {
                .idle => .none,
                .posted => .close_posted,
                .transit => .wait_ack,
                // Nothing is posted to cancel: the queued repost packet is already on its way, and
                // retiring it is what lets the acceptor finish its drain.
                .deferred => .none,
            };
        }

        pub fn liveCount(self: *const Core) u32 {
            var total: u32 = 0;
            for (self.states) |slot_state| {
                if (slot_state != .idle) total += 1;
            }
            return total;
        }

        pub fn postedCount(self: *const Core) u32 {
            var total: u32 = 0;
            for (self.states) |slot_state| {
                if (slot_state == .posted) total += 1;
            }
            return total;
        }

        pub fn stop(self: *Core) void {
            self.stopping = true;
        }

        /// One AcceptEx completion, decided purely.
        ///
        /// This is the reference's AcceptorCore::on_completion: the slot state moves here and the
        /// caller is told what to do next, so the decision can be replayed with no listener, no
        /// completion port and no operation record.
        pub fn onCompletion(self: *Core, index: u32, completed: bool, code: i32) AcceptAction {
            const current = self.state(index) orelse
                return .{ .fail = .{ .index = index, .code = c.ERROR_INVALID_DATA } };
            if (current != .posted) {
                // A completion for a slot that was never posted means the port is delivering packets
                // this acceptor does not own.
                return .{ .fail = .{ .index = index, .code = c.ERROR_INVALID_DATA } };
            }
            if (!completed) {
                self.states[index] = .idle;
                if (self.stopping) return .none;
                // A connection-level abort leaves the listener healthy, so the slot is reused.
                if (acceptErrorIsRecoverable(code)) return .{ .repost = index };
                return .{ .fail = .{ .index = index, .code = code } };
            }
            // The caller withdraws a completion that races the stop before it reaches here, so a
            // handoff decision is only ever produced while admission is still running.
            if (self.worker_count == 0) {
                return .{ .fail = .{ .index = index, .code = c.ERROR_INVALID_DATA } };
            }
            const candidate = self.rotation % self.worker_count;
            self.rotation = self.rotation +% 1;
            self.states[index] = .transit;
            return .{ .handoff = .{ .index = index, .worker = candidate } };
        }

        /// A worker acknowledged a handoff, or a deferred slot's queued repost is being retired.
        ///
        /// This is the reference's on_ack. Whatever socket is left in the slot belongs to the
        /// acceptor again, so the slot returns to idle and the caller is told whether to post again.
        pub fn onAck(self: *Core, index: u32) AcceptAction {
            const current = self.state(index) orelse
                return .{ .fail = .{ .index = index, .code = c.ERROR_INVALID_DATA } };
            // An acknowledgement without a handoff, or for a slot that is neither in transit nor
            // deferred, means the port delivered control this acceptor does not own.
            if (current != .transit and current != .deferred) {
                return .{ .fail = .{ .index = index, .code = c.ERROR_INVALID_DATA } };
            }
            self.states[index] = .idle;
            // A stopping acceptor retires the slot without arming another post.
            if (self.stopping) return .none;
            return .{ .repost = index };
        }

        /// Returns a slot to idle after its completion was withdrawn rather than acted on, from
        /// either state a pending completion can leave behind.
        ///
        /// This is the reference's abort_handoff, generalised to the posted case: the same slot is
        /// withdrawn whether the stop closed its socket before the completion arrived (posted) or
        /// after this acceptor had already decided to hand it to a worker (transit). Without it a
        /// slot whose socket disappeared would stay live forever, and the acceptor would wait for a
        /// completion that has already been consumed.
        pub fn returnSlot(self: *Core, index: u32) bool {
            return self.transition(index, .posted, .idle) or self.transition(index, .transit, .idle);
        }

        /// Starts the credit scan at the candidate the rotation chose and takes the first worker that
        /// still has a credit. The candidate is a hint rather than a promise: a saturated worker is
        /// skipped instead of being handed a socket it would have to refuse.
        pub fn reserveWorker(self: *Core, candidate: u32, credits: []AdmissionCredits) ?u32 {
            self.rotation = candidate;
            return selectWorker(credits, &self.rotation, self.worker_count);
        }
    };

    pub const Operation = struct {
        overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
        owner: ?*Acceptor = null,
        socket: c.SOCKET = c.INVALID_SOCKET,
        socket_owner: native.socket.Socket = .{},
        acceptor_port: c.HANDLE = null,
        index: u32 = 0,
        addresses: [types.accept_operation_bytes]u8 = @splat(0),
        provider_owned: bool = false,
    };

    pub const Acceptor = struct {
        drain_started: ?u64 = null,
        last_failure: ?types.Failure = null,
        // Native ownership, read and written only by the acceptor thread and its lifecycle calls.
        listener: native.socket.Socket = .{},
        port: native.handle.Handle = .{},
        thread: native.handle.ThreadHandle = .{},
        ready_event: native.handle.EventHandle = .{},
        operations: []Operation = &.{},
        accept_ex: ?c.LPFN_ACCEPTEX = null,
        get_accept_addresses: ?c.LPFN_GETACCEPTEXSOCKADDRS = null,

        api: ?*const native.rio.Api = null,
        options: ?*const types.Options = null,
        workers: []TcpWorker = &.{},
        credits: []AdmissionCredits = &.{},
        failed: ?*std.atomic.Value(bool) = null,
        /// Storage for the pure accept state.
        states: []State = &.{},
        /// The pure accept state machine: transitions, rotation and the admission tallies.
        core: Core = .{},
        ready: bool = false,
        startup_ok: bool = false,

        pub fn workerCount(self: *const Acceptor) u32 {
            return @intCast(self.workers.len);
        }

        pub fn operationCount(self: *const Acceptor) u32 {
            return @intCast(self.operations.len);
        }

        /// What the shutdown path would do with one slot right now.
        ///
        /// Exposed so a test can observe the boundary this acceptor actually draws while the stop is
        /// running, instead of inferring it from the outcome: a slot reported as wait_ack is one the
        /// stop must leave to the worker that is adopting it.
        pub fn disposition(self: *const Acceptor, index: u32) SlotDisposition {
            return self.core.dispositionFor(index);
        }

        /// True once the stop has begun unpublishing admission, which is the point after which the
        /// slot boundary above is the one in force.
        pub fn stopping(self: *const Acceptor) bool {
            return self.core.stopping;
        }

        /// Operations that are still posted or in transit; the acceptor must retire all of them
        /// before it can release its listener and its accept table.
        pub fn liveCount(self: *const Acceptor) u32 {
            return self.core.liveCount();
        }

        pub fn postedCount(self: *const Acceptor) u32 {
            return self.core.postedCount();
        }
    };

    pub const InitError = error{
        WorkerCount,
        Listener,
        Port,
        ReadyEvent,
        ConfigureSocket,
        BindListen,
        AssociateIocp,
        AcceptExExtension,
        AddressExtension,
        Operations,
        Credits,
    };

    fn failFast(stage: []const u8, native_error: u32) noreturn {
        native.diagnostics.failFast(stage, native_error);
    }

    fn operationInRange(self: *const Acceptor, operation: *const Operation) bool {
        if (self.operations.len == 0) return false;
        const address = @intFromPtr(operation);
        const base = @intFromPtr(self.operations.ptr);
        const end = base + self.operations.len * @sizeOf(Operation);
        return address >= base and address < end and (address - base) % @sizeOf(Operation) == 0;
    }

    fn closeAccepted(operation: *Operation) void {
        operation.socket_owner.deinit();
        operation.socket = c.INVALID_SOCKET;
    }

    /// Posts one AcceptEx. A connection-level refusal is retried synchronously a bounded number of
    /// times; once those are spent the slot yields to a queued repost packet instead of spinning on
    /// a queue that keeps refusing it.
    pub fn postAccept(self: *Acceptor, operation: *Operation) bool {
        if (operation.provider_owned) failFast("AcceptEx repost ownership", c.ERROR_INVALID_STATE);
        var attempt: u32 = 0;
        while (attempt < synchronous_attempts) : (attempt += 1) {
            if (self.core.stopping or self.failed.?.load(.acquire) or self.listener.get() == c.INVALID_SOCKET) return true;
            operation.overlapped = std.mem.zeroes(c.OVERLAPPED);
            operation.socket_owner.reset(native.socket.registered(c.SOCK_STREAM, c.IPPROTO_TCP));
            operation.socket = operation.socket_owner.get();
            if (operation.socket == c.INVALID_SOCKET) {
                self.last_failure = native.winsockFailure("WSASocketW(accepted RIO socket)");
                native.diagnostics.reportFailure(self.last_failure.?);
                self.core.network_errors +%= 1;
                return false;
            }
            if (!self.core.transition(operation.index, .idle, .posted)) {
                failFast("accept post state", c.ERROR_INVALID_STATE);
            }
            var received: c.DWORD = 0;
            const accepted = self.accept_ex.?(
                self.listener.get(),
                operation.socket,
                &operation.addresses,
                0,
                types.accept_address_bytes,
                types.accept_address_bytes,
                &received,
                &operation.overlapped,
            );
            if (accepted != c.FALSE) {
                operation.provider_owned = true;
                return true;
            }
            const status = c.WSAGetLastError();
            // AcceptEx is asynchronous: a pending result is the normal outcome, and only any other
            // refusal means the operation was never queued.
            if (status == @as(i32, @intCast(c.ERROR_IO_PENDING))) {
                operation.provider_owned = true;
                return true;
            }
            _ = self.core.transition(operation.index, .posted, .idle);
            closeAccepted(operation);
            // A refused attempt is a network error whether or not it can be retried, exactly as the
            // reference counts it.
            self.core.network_errors +%= 1;
            if (!acceptErrorIsRecoverable(status)) {
                self.last_failure = .{ .stage = "AcceptEx", .code = status };
                native.diagnostics.reportFailure(self.last_failure.?);
                return false;
            }
        }
        // The synchronous budget is spent. The slot is retried from the loop below rather than here,
        // and the queued packet is what keeps a deferred slot live until it is retired.
        if (!self.core.transition(operation.index, .idle, .deferred)) failFast("accept defer state", c.ERROR_INVALID_STATE);
        if (!native.rio.postCompletion(self.port.get(), @intFromPtr(operation), null)) {
            failFast("PostQueuedCompletionStatus(deferred AcceptEx repost)", c.GetLastError());
        }
        return true;
    }

    /// Executes the acknowledgement the core decided. The transition and the repost-or-retire choice
    /// are the core's; this only carries them out.
    fn resumeSlot(self: *Acceptor, operation: *Operation) void {
        switch (self.core.onEvent(.{ .acknowledged = operation.index })) {
            .none => {},
            .fail => failFast("accept acknowledgement state", c.ERROR_INVALID_DATA),
            .repost => {
                if (!postAccept(self, operation)) {
                    stopAfterFailure(self);
                }
            },
            .handoff => failFast("accept acknowledgement action", c.ERROR_INVALID_DATA),
        }
    }

    fn failAndStop(self: *Acceptor, stage: []const u8, native_error: u32) void {
        native.diagnostics.report(stage, native_error);
        stopAfterFailure(self);
    }

    fn stopAfterFailure(self: *Acceptor) void {
        self.failed.?.store(true, .release);
        beginStop(self);
    }

    /// Unposts admission: the listener goes away and every posted AcceptEx is cancelled.
    ///
    /// Only a posted slot is closed. A slot in transit has already been published to a worker, and
    /// the acceptor is no longer the owner of that socket -- the worker takes it, or withdraws it and
    /// acknowledges. Closing it here would race the worker's take() on the same ownership record and
    /// pull a live socket out from under a handoff that is about to be adopted, which is the same
    /// WSAENOTSOCK this file just stopped producing. A deferred slot has no AcceptEx to cancel.
    ///
    /// Both references draw the boundary in exactly this place: the acceptor's stop only closes
    /// posted slots, while the unconditional sweep over every slot belongs to the release path,
    /// which runs after the thread is joined and no completion is outstanding.
    pub fn beginStop(self: *Acceptor) void {
        if (self.core.stopping) return;
        self.drain_started = native.nowMilliseconds();
        _ = self.core.onEvent(.stop);
        self.listener.deinit();
        for (self.operations) |*operation| {
            // Closing the accepted socket cancels its outstanding AcceptEx; the completion is then
            // retired by the loop instead of leaving the operation posted forever.
            if (self.core.dispositionFor(operation.index) == .close_posted) closeAccepted(operation);
        }
    }

    fn canPublishReady(listener: c.SOCKET, posted: u32, total: u32) bool {
        return listener != c.INVALID_SOCKET and total != 0 and posted == total;
    }

    fn publishReady(self: *Acceptor, posted: u32) void {
        self.startup_ok = canPublishReady(self.listener.get(), posted, self.operationCount());
        self.ready = true;
        if (c.SetEvent(self.ready_event.get()) == c.FALSE) failFast("SetEvent(acceptor ready)", c.GetLastError());
    }

    /// Retires a slot whose completion this acceptor will not act on: the socket it holds is closed
    /// and the slot returns to idle without arming another post. The transition is the same whether
    /// the slot was still posted or already moved to transit for a handoff.
    fn withdrawSlot(self: *Acceptor, operation: *Operation) void {
        if (!self.core.returnSlot(operation.index)) failFast("accept withdrawal state", c.ERROR_INVALID_STATE);
        closeAccepted(operation);
    }

    fn completeAccept(self: *Acceptor, operation: *Operation, packet_ok: bool, native_error: u32) void {
        // GetQueuedCompletionStatus is the single completion source here, exactly as in the
        // reference: the dequeue reports the I/O outcome and its error, so a second
        // WSAGetOverlappedResult query could only disagree with it. AcceptEx transfers no payload
        // this server consumes, and the extra call would name the listener rather than the accepted
        // socket. The decision is the core's: it moves the slot and names the next step. The loop has
        // already proved this slot is posted and owned, so the only outcomes here are the ones a real
        // completion produces, and every one of them is executed below rather than decided here.
        switch (self.core.onEvent(.{ .completion = .{ .index = operation.index, .completed = packet_ok, .code = @bitCast(native_error) } })) {
            .none => return,
            .fail => |failure| {
                // The slot is unposted by beginStop, so a failure that arrives under stopping is the
                // cancellation the stop asked for and is not a fault of this run. See
                // acceptorCountsFailure for why the global failure flag stays out of the ledger too.
                if (acceptorCountsFailure(self.core.stopping, self.failed.?.load(.acquire))) self.core.network_errors +%= 1;
                closeAccepted(operation);
                failAndStop(self, "AcceptEx completion", @bitCast(failure.code));
            },
            .repost => {
                if (acceptorCountsFailure(self.core.stopping, self.failed.?.load(.acquire))) self.core.network_errors +%= 1;
                closeAccepted(operation);
                if (!postAccept(self, operation)) {
                    stopAfterFailure(self);
                }
            },
            .handoff => |handoff| executeHandoff(self, operation, handoff.worker),
        }
    }

    /// Executes a handoff the core decided: configure the accepted socket, resolve its addresses,
    /// take a worker credit and publish. All of it is I/O -- the slot is already in transit, so a
    /// failure here retires it rather than re-deciding.
    fn executeHandoff(self: *Acceptor, operation: *Operation, candidate: u32) void {
        // The withdrawal guard, matching the reference. A successful AcceptEx completion can still be
        // sitting in the port when the stop arrives: beginStop closes the listener and every socket
        // whose slot is still posted, and that socket is exactly the one this handoff would configure.
        // A withdrawing acceptor closes the slot instead of calling SO_UPDATE_ACCEPT_CONTEXT on a
        // socket that is already gone, and the close is idempotent because beginStop leaves
        // INVALID_SOCKET behind, so an unpost that raced the completion retires quietly and is not
        // counted as a new network fault. The decision itself is the pure one above.
        switch (requireHandoffDisposition(self.core.stopping, self.failed.?.load(.acquire), self.listener.get() != c.INVALID_SOCKET, operation.socket != c.INVALID_SOCKET)) {
            .withdraw => {
                withdrawSlot(self, operation);
                return;
            },
            .fatal => unreachable,
            .handoff => {},
        }
        const context_failure = native.endpoint.updateAcceptContext(operation.socket, self.listener.get());
        const configuration = context_failure orelse
            native.socket.configure(operation.socket, self.options.?.socket_buffer_bytes, true);
        if (configuration) |failure| {
            self.core.network_errors +%= 1;
            // The status was captured at the call that produced it, so the transition and the socket
            // cleanup below cannot replace the reason this failed.
            if (!self.core.transition(operation.index, .transit, .idle)) failFast("accept configure state", c.ERROR_INVALID_STATE);
            closeAccepted(operation);
            // The baseline's context-update failure is counted and stops admission quietly.
            // Socket configuration has its own single diagnostic; neither path adds another.
            if (context_failure == null) native.diagnostics.report(failure.stage, @bitCast(failure.native_error));
            stopAfterFailure(self);
            return;
        }
        var local: ?*c.SOCKADDR = null;
        var remote: ?*c.SOCKADDR = null;
        var local_length: c_int = 0;
        var remote_length: c_int = 0;
        self.get_accept_addresses.?(
            &operation.addresses,
            0,
            types.accept_address_bytes,
            types.accept_address_bytes,
            &local,
            &local_length,
            &remote,
            &remote_length,
        );
        if (local == null or remote == null or local_length <= 0 or remote_length <= 0) {
            if (!self.core.transition(operation.index, .transit, .idle)) failFast("accept address state", c.ERROR_INVALID_STATE);
            closeAccepted(operation);
            failAndStop(self, "GetAcceptExSockaddrs", c.WSAEINVAL);
            return;
        }
        // Round-robin over the workers that still hold a credit: a saturated worker is never handed
        // a socket it would have to refuse.
        const worker_index = self.core.reserveWorker(candidate, self.credits) orelse {
            if (!self.core.transition(operation.index, .transit, .idle)) failFast("accept capacity state", c.ERROR_INVALID_STATE);
            closeAccepted(operation);
            self.core.rejected +%= 1;
            if (!postAccept(self, operation)) {
                stopAfterFailure(self);
            }
            return;
        };
        worker.tcp.postHandoff(&self.workers[worker_index], operation);
    }

    fn threadEntry(parameter: ?*anyopaque) callconv(.winapi) c.DWORD {
        const self: *Acceptor = @ptrCast(@alignCast(parameter.?));
        return acceptorThread(self);
    }

    fn acceptorThread(self: *Acceptor) c.DWORD {
        var posted: u32 = 0;
        for (self.operations) |*operation| {
            if (!postAccept(self, operation)) {
                self.failed.?.store(true, .release);
                beginStop(self);
                break;
            }
            posted += 1;
        }
        publishReady(self, posted);
        var expired_packets: u32 = 0;

        while (!self.core.stopping or self.liveCount() != 0) {
            // A worker that failed publishes the global flag before the coordinator posts the stop
            // control message. Unposting here instead of waiting for that message keeps this acceptor
            // from admitting connections into a run that is already failing, which is what the
            // reference does with the same test at the top of its loop.
            if (!self.core.stopping and self.failed.?.load(.acquire)) {
                beginStop(self);
                if (self.liveCount() == 0) break;
            }
            const drain_due = if (self.drain_started) |started|
                native.nowMilliseconds() - started >= types.drain_milliseconds
            else
                false;
            const packet = native.rio.getQueuedCompletionStatus(self.port.get(), if (drain_due) 0 else 100);
            if (drain_due) {
                if ((!packet.ok and packet.native_error == c.WAIT_TIMEOUT and packet.overlapped == null) or
                    expired_packets >= self.operationCount() + 1)
                {
                    failFast("TCP acceptor drain deadline", c.ERROR_TIMEOUT);
                }
                expired_packets += 1;
            } else expired_packets = 0;
            if (packet.overlapped == null and packet.key == types.stop_key) {
                beginStop(self);
                continue;
            }
            if (packet.overlapped == null and packet.key > types.admission_closed_key) {
                // One queued control packet per accept slot: either a worker finished adopting or
                // withdrawing the socket it was handed, or the slot yielded to a deferred repost.
                const operation: *Operation = @ptrFromInt(packet.key);
                if (!operationInRange(self, operation)) failFast("accept control identity", c.ERROR_INVALID_DATA);
                switch (self.core.state(operation.index) orelse .idle) {
                    .transit, .deferred => resumeSlot(self, operation),
                    else => failFast("accept control state", c.ERROR_INVALID_DATA),
                }
                continue;
            }

            if (packet.overlapped != null) {
                const operation: *Operation = @fieldParentPtr("overlapped", packet.overlapped.?);
                if (!operationInRange(self, operation) or self.core.state(operation.index) != .posted or !operation.provider_owned) {
                    failFast("AcceptEx completion identity", c.ERROR_INVALID_DATA);
                }
                // AcceptEx was posted with zero receive bytes. Validate before returning ownership.
                if (packet.transferred != 0) failFast("AcceptEx completion payload extent", c.ERROR_INVALID_DATA);
                operation.provider_owned = false;
                if (!packet.ok and self.core.stopping) {
                    if (!self.core.transition(operation.index, .posted, .idle)) failFast("cancelled accept state", c.ERROR_INVALID_STATE);
                    closeAccepted(operation);
                } else {
                    completeAccept(self, operation, packet.ok, packet.native_error);
                }
                continue;
            }
            if (!packet.ok and packet.native_error != c.WAIT_TIMEOUT) {
                self.core.network_errors +%= 1;
                failAndStop(self, "GetQueuedCompletionStatus(acceptor)", packet.native_error);
            } else if (!(!packet.ok and packet.native_error == c.WAIT_TIMEOUT and packet.overlapped == null)) {
                failFast("unexpected acceptor IOCP packet", c.ERROR_INVALID_DATA);
            }
        }
        // The acceptor publishes nothing on its way out. Admission is the coordinator's barrier:
        // it owns the transition, it knows which workers actually started, and a worker can never
        // wait for a closure that nobody publishes because the coordinator always reaches it.
        return if (self.failed.?.load(.acquire)) 1 else 0;
    }

    pub fn initialize(
        self: *Acceptor,
        api: *const native.rio.Api,
        options: *const types.Options,
        workers: []TcpWorker,
        credits: []AdmissionCredits,
        failed: *std.atomic.Value(bool),
    ) InitError!void {
        switch (initializeResult(self, api, options, workers, credits, failed)) {
            .value => {},
            .failure => |failure| {
                native.diagnostics.reportFailure(failure);
                return error.Listener;
            },
        }
    }

    pub fn initializeResult(
        self: *Acceptor,
        api: *const native.rio.Api,
        options: *const types.Options,
        workers: []TcpWorker,
        credits: []AdmissionCredits,
        failed: *std.atomic.Value(bool),
    ) native.Result(void) {
        const allocator = std.heap.page_allocator;
        self.* = .{};
        var initialized = false;
        defer if (!initialized) destroy(self);
        if (workers.len == 0 or workers.len > std.math.maxInt(u32)) return .{ .failure = types.Failure.invariant("acceptor worker count") };
        if (credits.len != workers.len) return .{ .failure = types.Failure.invariant("acceptor credit count") };
        self.api = api;
        self.options = options;
        self.workers = workers;
        self.credits = credits;
        self.failed = failed;

        self.listener.reset(native.socket.registered(c.SOCK_STREAM, c.IPPROTO_TCP));
        if (self.listener.get() == c.INVALID_SOCKET) {
            return .{ .failure = native.winsockFailure("WSASocketW(TCP listener)") };
        }
        self.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
        if (self.port.value == null or self.port.value == c.INVALID_HANDLE_VALUE) {
            return .{ .failure = native.win32Failure("CreateIoCompletionPort(acceptor)") };
        }
        self.ready_event.reset(c.CreateEventW(null, c.TRUE, c.FALSE, null));
        if (self.ready_event.value == null) {
            return .{ .failure = native.win32Failure("TCP acceptor event creation") };
        }
        if (native.socket.configure(self.listener.get(), options.socket_buffer_bytes, true)) |failure| {
            return .{ .failure = .{ .stage = failure.stage, .code = failure.native_error } };
        }
        if (native.endpoint.bindFailure(self.listener.get(), options.port)) |failure| {
            var diagnostic = failure;
            diagnostic.stage = "bind/listen";
            return .{ .failure = diagnostic };
        }
        if (native.endpoint.listenFailure(self.listener.get())) |failure| {
            var diagnostic = failure;
            diagnostic.stage = "bind/listen";
            return .{ .failure = diagnostic };
        }
        const listener_handle: c.HANDLE = @ptrFromInt(self.listener.get());
        if (c.CreateIoCompletionPort(listener_handle, self.port.get(), 0, 1) != self.port.get()) {
            return .{ .failure = native.win32Failure("CreateIoCompletionPort(listener association)") };
        }
        self.accept_ex = switch (native.endpoint.acceptExtensionResult(self.listener.get())) {
            .value => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };
        self.get_accept_addresses = switch (native.endpoint.acceptAddressesExtensionResult(self.listener.get())) {
            .value => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };

        const count = operation_count(self.workerCount());
        self.states = allocator.alloc(State, count) catch {
            return .{ .failure = .{ .stage = "AcceptEx operation allocation", .code = types.error_not_enough_memory, .domain = .allocation } };
        };
        self.core = Core.init(self.states);
        // Set after the core is built: Core.init replaces the whole record, so a count written before
        // it would be wiped and the rotation would have no workers to walk.
        self.core.worker_count = @intCast(workers.len);
        self.operations = allocator.alloc(Operation, count) catch {
            return .{ .failure = .{ .stage = "AcceptEx operation allocation", .code = types.error_not_enough_memory, .domain = .allocation } };
        };
        for (self.operations, 0..) |*operation, index| {
            operation.* = .{
                .owner = self,
                .acceptor_port = self.port.get(),
                .index = @intCast(index),
            };
        }
        initialized = true;
        return .{ .value = {} };
    }

    pub fn start(self: *Acceptor) bool {
        self.thread.reset(c.CreateThread(null, 0, threadEntry, self, 0, null));
        if (self.thread.value == null) {
            native.diagnostics.report("CreateThread(acceptor)", c.GetLastError());
            return false;
        }
        if (c.WaitForSingleObject(self.ready_event.get(), types.infinite) != types.wait_object_0 or
            !self.ready)
        {
            native.diagnostics.report("acceptor startup readiness", c.ERROR_INVALID_STATE);
            return false;
        }
        // Initial postAccept failure already reported its native cause. Keep the readiness
        // handshake quiet for that failure, matching the baseline's single diagnostic.
        return self.startup_ok;
    }

    pub fn stop(self: *Acceptor) void {
        if (self.port.value == null) return;
        if (!native.rio.postCompletion(self.port.get(), types.stop_key, null)) {
            native.guards.requireControlPost(c.FALSE, c.GetLastError(), "PostQueuedCompletionStatus(acceptor stop)");
        }
    }

    pub fn join(self: *Acceptor) void {
        if (self.thread.value != null and c.WaitForSingleObject(self.thread.value, types.infinite) != types.wait_object_0) {
            native.guards.requireControlPost(c.FALSE, c.GetLastError(), "WaitForSingleObject(acceptor)");
        }
    }

    pub fn requireRelease(self: *const Acceptor) void {
        if (self.core.liveCount() != 0) {
            native.diagnostics.failFast("TCP acceptor terminal operations", c.ERROR_IO_INCOMPLETE);
        }
        for (self.operations) |operation| {
            if (operation.provider_owned) native.diagnostics.failFast("TCP acceptor terminal operations", c.ERROR_IO_INCOMPLETE);
        }
    }

    /// Releases the accept table, the listener, the event and the port. Every published handoff has
    /// already been acknowledged and every posted accept retired, so nothing is left in flight.
    /// Stops the acceptor, waits for its thread, proves that Windows no longer owns any accept slot,
    /// and only then releases the table and the state.
    ///
    /// The proof has to live here rather than at the caller. A live slot means a posted AcceptEx or a
    /// published handoff was never retired, so the listener and the registered address records can
    /// still be referenced; freeing them would be a use-after-free. Failing fast at the release
    /// boundary is what makes that unreachable from the coordinator, from an initialisation error and
    /// from a test driver alike.
    pub fn destroy(self: *Acceptor) void {
        const allocator = std.heap.page_allocator;
        join(self);
        requireRelease(self);
        self.thread.deinit();
        for (self.operations) |*operation| closeAccepted(operation);
        if (self.operations.len != 0) allocator.free(self.operations);
        self.operations = &.{};
        if (self.states.len != 0) allocator.free(self.states);
        self.states = &.{};
        self.core.states = &.{};
        self.listener.deinit();
        self.ready_event.deinit();
        self.port.deinit();
        self.ready = false;
        self.workers = &.{};
        self.credits = &.{};
    }
};

/// The TCP worker record. The pure aggregate it drives lives in engine.zig; everything below the
/// engine field is a native owner.
pub const TcpWorker = struct {
    port: native.handle.Handle = .{},
    thread: native.handle.ThreadHandle = .{},
    ready_event: native.handle.EventHandle = .{},
    arena: native.arena.Arena = .{},
    completion_queue: native.rio.CompletionQueue = .{},
    connection_sockets: []native.socket.Socket = &.{},
    request_queues: []c.RIO_RQ = &.{},
    provider_requests: []worker.ProviderRequest = &.{},
    provider_outstanding: u32 = 0,
    steps: []engine.Step = &.{},
    engine_value: engine.TcpEngine = .{},
    credits: ?*acceptor.AdmissionCredits = null,
    notification_overlapped: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),

    api: ?*const native.rio.Api = null,
    options: ?*const types.Options = null,
    failed: ?*std.atomic.Value(bool) = null,
    worker_index: u32 = 0,
    notification_arms: u64 = 0,
    notification_deliveries: u64 = 0,
    timeout_wakeups: u64 = 0,
    drain_started: ?u64 = null,
    ready: bool = false,

    pub fn stride(self: *const TcpWorker) u32 {
        return native.arena.tcpStride(self.options.?.rio_buffer_bytes);
    }

    pub fn outstanding(self: *const TcpWorker) u32 {
        return self.engine_value.outstanding();
    }
};

/// The datagram engine. A slot alternates between receiving one datagram and echoing it back, and
/// each direction is tracked on its own so a closed receive can never be confused with a completed
/// send.
pub const udp = struct {
    pub const Slot = struct {
        payload: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
        remote_address: c.RIO_BUF = .{ .BufferId = c.RIO_INVALID_BUFFERID, .Offset = 0, .Length = 0 },
        provider_operation: ?types.EngineOperation = null,
        posted_length: u32 = 0,
    };

    /// Legacy classification vocabulary; production decisions carry their complete payload below.
    pub const Action = enum(u8) { repost_receive, repost_send, drop, fatal };
    pub const PostAction = struct { index: u32, operation: types.EngineOperation, payload_length: u32 };
    pub const UdpAction = union(enum) {
        post: PostAction,
        fatal: struct { index: u32, failure: types.Failure },
        none,
    };
    pub const Event = union(enum) {
        completion: types.Completion,
        post_failed: struct { index: u32, failure: types.Failure },
        stop,
        drained,
    };
    pub const SlotState = struct {
        direction: types.EngineOperation = .receive,
        payload_length: u32 = 0,
        outstanding: bool = false,
    };

    /// Pure UDP state. Native resources and post execution belong exclusively to Runtime.
    pub const Engine = struct {
        slots: []SlotState = &.{},
        payload_bytes: u32 = 0,
        outstanding: u32 = 0,
        phase: types.UdpPhase = .running,
        statistics: types.Statistics = .{},
        closing: bool = false,
        failed: bool = false,
        failure: ?types.Failure = null,

        pub fn init(slots: []SlotState) Engine {
            return initWithCapacity(slots, @intCast(types.maximum_udp_payload));
        }

        pub fn initWithCapacity(slots: []SlotState, capacity: u32) Engine {
            for (slots) |*slot| slot.* = .{ .payload_length = capacity };
            return .{ .slots = slots, .payload_bytes = capacity };
        }

        pub fn direction(self: *const Engine, index: u32) types.EngineOperation {
            return if (index < self.slots.len) self.slots[index].direction else .receive;
        }

        pub fn initialPost(self: *const Engine, index: u32) UdpAction {
            if (index >= self.slots.len or self.closing or self.slots[index].outstanding) {
                return .{ .fatal = .{ .index = index, .failure = types.Failure.invariant("UDP post ownership") } };
            }
            return .{ .post = .{ .index = index, .operation = self.slots[index].direction, .payload_length = self.slots[index].payload_length } };
        }

        /// Called only after the provider accepted this request. Refusal is an invariant failure.
        pub fn markPosted(self: *Engine, index: u32) bool {
            if (index >= self.slots.len or self.closing or self.slots[index].outstanding or
                self.outstanding >= self.slots.len) return false;
            self.slots[index].outstanding = true;
            self.outstanding += 1;
            return true;
        }

        pub fn onPosted(self: *Engine, index: u32, operation: types.EngineOperation) bool {
            if (index >= self.slots.len or self.closing or self.slots[index].outstanding) return false;
            self.slots[index].direction = operation;
            if (operation == .receive) self.slots[index].payload_length = self.payload_bytes;
            return self.markPosted(index);
        }

        pub fn hasWork(self: *const Engine) bool {
            return self.outstanding != 0;
        }

        pub fn beginClose(self: *Engine) void {
            self.closing = true;
            if (self.phase == .running) self.phase = .draining;
        }

        pub fn lifecycle(self: *const Engine) types.UdpLifecycle {
            return .{ .phase = self.phase, .outstanding = self.outstanding, .closing = self.closing, .failed = self.failed };
        }

        pub fn mayRelease(self: *const Engine) bool {
            return self.lifecycle().mayRelease();
        }

        fn fail(self: *Engine, index: u32, failure: types.Failure) UdpAction {
            self.failure = failure;
            self.failed = true;
            self.beginClose();
            return .{ .fatal = .{ .index = index, .failure = failure } };
        }

        pub fn onEvent(self: *Engine, event: Event) UdpAction {
            switch (event) {
                .stop => {
                    self.beginClose();
                    return .none;
                },
                .drained => {
                    if (self.outstanding != 0 or !self.closing) {
                        return .{ .fatal = .{ .index = 0, .failure = types.Failure.invariant("UDP release precondition") } };
                    }
                    self.phase = .stopped;
                    return .none;
                },
                .post_failed => |value| {
                    // A refused submission never entered the provider. It cannot erase older work.
                    if (value.index >= self.slots.len or self.slots[value.index].outstanding) {
                        return .{ .fatal = .{ .index = value.index, .failure = types.Failure.invariant("UDP refused post ownership") } };
                    }
                    self.statistics.network_errors +%= 1;
                    return self.fail(value.index, value.failure);
                },
                .completion => |value| {
                    if (value.index >= self.slots.len or self.outstanding == 0 or
                        !self.slots[value.index].outstanding or self.slots[value.index].direction != value.operation)
                    {
                        return .{ .fatal = .{ .index = value.index, .failure = types.Failure.invariant("UDP completion invariant") } };
                    }
                    const slot = &self.slots[value.index];
                    slot.outstanding = false;
                    self.outstanding -= 1;
                    self.statistics.completions +%= 1;
                    if (value.status == types.error_success) {
                        switch (value.operation) {
                            .receive => {
                                self.statistics.receives +%= 1;
                                self.statistics.received_bytes +%= value.bytes;
                            },
                            .send => {
                                self.statistics.sends +%= 1;
                                self.statistics.sent_bytes +%= value.bytes;
                                self.statistics.bytes +%= value.bytes;
                            },
                        }
                    } else if (!self.closing) self.statistics.network_errors +%= 1;
                    if (self.closing) return .none;
                    if (value.status != types.error_success) {
                        if (value.status != types.wsa_econnreset) {
                            return self.fail(value.index, .{ .stage = "UDP RIO completion", .code = value.status });
                        }
                        slot.direction = .receive;
                        slot.payload_length = self.payload_bytes;
                    } else if (value.operation == .receive) {
                        slot.direction = .send;
                        slot.payload_length = value.bytes;
                    } else {
                        slot.direction = .receive;
                        slot.payload_length = self.payload_bytes;
                    }
                    return .{ .post = .{ .index = value.index, .operation = slot.direction, .payload_length = slot.payload_length } };
                },
            }
        }

        pub fn onCompletion(self: *Engine, index: u32, status: i32, bytes: u32, capacity: u32) Action {
            self.payload_bytes = capacity;
            return switch (self.onEvent(.{ .completion = .{ .index = index, .operation = self.direction(index), .status = status, .bytes = bytes } })) {
                .post => |value| if (value.operation == .receive) .repost_receive else .repost_send,
                .fatal => .fatal,
                .none => .drop,
            };
        }

        pub fn onPostFailure(self: *Engine) void {
            self.statistics.network_errors +%= 1;
            self.failed = true;
            self.failure = .{ .stage = "UDP post failure", .code = types.error_invalid_data };
            self.beginClose();
        }
    };

    pub fn classify(operation: types.EngineOperation, status: i32, bytes: u32, capacity: u32) Action {
        _ = bytes;
        _ = capacity;
        if (status == types.wsa_econnreset) return .repost_receive;
        if (status != types.error_success) return .fatal;
        return if (operation == .receive) .repost_send else .repost_receive;
    }

    pub fn receiveLength(bytes: u32, capacity: u32) u32 {
        return @min(bytes, capacity);
    }

    pub const runtime = struct {
        fn failFast(stage: []const u8, code: u32) noreturn {
            native.diagnostics.failFast(stage, code);
        }

        const Runtime = struct {
            const allocator = std.heap.page_allocator;
            api: *const native.rio.Api,
            capacity: u32,
            socket_owner: native.socket.Socket = .{},
            port: native.handle.Handle = .{},
            arena_value: native.arena.Arena = .{},
            slot_states: []SlotState = &.{},
            slots: []Slot = &.{},
            queue: native.rio.CompletionQueue = .{},
            request_queue: c.RIO_RQ = c.RIO_INVALID_RQ,
            notification: c.OVERLAPPED = std.mem.zeroes(c.OVERLAPPED),
            engine_value: Engine = .{},
            snapshot: types.NotifySnapshot = .{},
            provider_outstanding: u32 = 0,
            drain_started: ?u64 = null,

            fn initializationFailure(self: *Runtime, failure: types.Failure, network_error: bool) native.Result(void) {
                if (network_error) self.engine_value.statistics.network_errors +%= 1;
                self.engine_value.failed = true;
                self.engine_value.failure = failure;
                self.engine_value.beginClose();
                return .{ .failure = failure };
            }

            fn initialize(self: *Runtime, options: *const types.Options, stride: u32) native.Result(void) {
                self.socket_owner.value = native.socket.registered(c.SOCK_DGRAM, c.IPPROTO_UDP);
                if (self.socket_owner.get() == c.INVALID_SOCKET) {
                    return self.initializationFailure(native.winsockFailure("WSASocketW(UDP RIO)"), true);
                }
                if (native.socket.configure(self.socket_owner.get(), options.socket_buffer_bytes, false)) |failure| {
                    return self.initializationFailure(.{ .stage = failure.stage, .code = failure.native_error }, true);
                }
                self.port.reset(c.CreateIoCompletionPort(c.INVALID_HANDLE_VALUE, null, 0, 1));
                if (self.port.value == null or self.port.value == c.INVALID_HANDLE_VALUE) {
                    return self.initializationFailure(native.win32Failure("CreateIoCompletionPort(UDP)"), false);
                }
                if (native.endpoint.bindFailure(self.socket_owner.get(), options.port)) |failure| {
                    var diagnostic = failure;
                    diagnostic.stage = "bind(UDP)";
                    return self.initializationFailure(diagnostic, true);
                }
                self.arena_value = switch (native.arena.Arena.createResult(self.api, options.udp_depth, stride)) {
                    .value => |value| value,
                    .failure => |failure| {
                        var diagnostic = failure;
                        diagnostic.stage = switch (failure.domain) {
                            .winsock => "UDP slot registrations",
                            .allocation => "UDP runtime allocation",
                            .win32 => "VirtualAlloc(UDP arena)",
                            .invariant => failure.stage,
                        };
                        return self.initializationFailure(diagnostic, failure.domain == .winsock);
                    },
                };
                self.slot_states = allocator.alloc(SlotState, options.udp_depth) catch
                    return self.initializationFailure(.{ .stage = "UDP runtime allocation", .code = types.error_not_enough_memory, .domain = .allocation }, false);
                self.engine_value = Engine.initWithCapacity(self.slot_states, self.capacity);
                self.slots = allocator.alloc(Slot, options.udp_depth) catch
                    return self.initializationFailure(.{ .stage = "UDP runtime allocation", .code = types.error_not_enough_memory, .domain = .allocation }, false);
                @memset(self.slots, .{});
                var notification: c.RIO_NOTIFICATION_COMPLETION = std.mem.zeroes(c.RIO_NOTIFICATION_COMPLETION);
                notification.Type = c.RIO_IOCP_COMPLETION;
                notification.Iocp.IocpHandle = self.port.get();
                notification.Iocp.CompletionKey = @ptrCast(self.slots.ptr);
                notification.Iocp.Overlapped = &self.notification;
                self.queue.reset(self.api, self.api.createCq(options.cq_capacity, &notification));
                if (!self.queue.valid()) {
                    return self.initializationFailure(native.winsockFailure("UDP RIO CQ creation"), true);
                }
                self.request_queue = self.api.createRq(self.socket_owner.get(), options.udp_depth, 1, options.udp_depth, 1, self.queue.value, self.queue.value, @ptrCast(self.slots.ptr));
                if (self.request_queue == c.RIO_INVALID_RQ) {
                    return self.initializationFailure(native.winsockFailure("RIOCreateRequestQueue(UDP)"), true);
                }
                return .{ .value = {} };
            }

            fn closeSocket(self: *Runtime) void {
                if (self.drain_started == null) self.drain_started = native.nowMilliseconds();
                self.socket_owner.deinit();
            }

            fn arm(self: *Runtime) void {
                if (!self.engine_value.hasWork() or self.queue.armed) return;
                self.notification = std.mem.zeroes(c.OVERLAPPED);
                native.guards.requireNotifySuccess(self.api.notify(self.queue.value), "RIONotify(UDP)");
                native.guards.requireTransition(contract.notificationMarkRearmed(&self.queue.armed), "UDP notification rearm transition");
                self.snapshot.arms +%= 1;
            }

            fn post(self: *Runtime, value: PostAction) ?types.Failure {
                if (value.index >= self.slots.len or self.slots[value.index].provider_operation != null or
                    self.provider_outstanding != self.engine_value.outstanding)
                {
                    return types.Failure.invariant("UDP post ownership");
                }
                var payload = self.arena_value.datagramView(value.index, 0, value.payload_length) orelse
                    return types.Failure.invariant("UDP payload registration extent");
                var remote = self.arena_value.datagramView(value.index, self.capacity, @intCast(types.udp_address_bytes)) orelse
                    return types.Failure.invariant("UDP address registration extent");
                const context_value: ?*anyopaque = @ptrCast(&self.slots[value.index]);
                const submitted_length = payload.Length;
                const accepted = switch (value.operation) {
                    .receive => self.api.receiveEx(self.request_queue, &payload, &remote, context_value),
                    .send => self.api.sendEx(self.request_queue, &payload, &remote, context_value),
                };
                if (!accepted) return native.winsockFailure(if (self.engine_value.statistics.completions == 0) "RIOReceiveEx(UDP)" else "UDP RIO repost");
                self.slots[value.index].payload = payload;
                self.slots[value.index].remote_address = remote;
                self.slots[value.index].provider_operation = value.operation;
                self.slots[value.index].posted_length = submitted_length;
                self.provider_outstanding += 1;
                native.guards.requireTransition(self.engine_value.markPosted(value.index), "UDP post ownership");
                return null;
            }

            fn execute(self: *Runtime, action: UdpAction) void {
                switch (action) {
                    .post => |value| {
                        if (self.post(value)) |failure| {
                            if (failure.classification == .internal) failFast(failure.stage, @bitCast(failure.code));
                            self.execute(self.engine_value.onEvent(.{ .post_failed = .{ .index = value.index, .failure = failure } }));
                        }
                    },
                    .fatal => |value| {
                        if (value.failure.classification == .internal) failFast(value.failure.stage, @bitCast(value.failure.code));
                        native.diagnostics.reportFailure(value.failure);
                        self.closeSocket();
                    },
                    .none => if (self.engine_value.closing) self.closeSocket(),
                }
            }

            fn processResult(self: *Runtime, result: c.RIORESULT) void {
                const raw = result.RequestContext orelse failFast("UDP null RequestContext", c.ERROR_INVALID_DATA);
                const index = self.completionIndex(@intFromPtr(raw));
                const operation = self.slots[index].provider_operation.?;
                if (result.BytesTransferred > self.slots[index].posted_length) {
                    failFast("UDP completion payload extent", c.ERROR_INVALID_DATA);
                }
                // Retire the native provider ownership before publishing the business event.
                self.slots[index].provider_operation = null;
                self.provider_outstanding -= 1;
                self.execute(self.engine_value.onEvent(.{ .completion = .{ .index = index, .operation = operation, .status = result.Status, .bytes = result.BytesTransferred } }));
            }

            /// CQ records can be queued before their pending notification reaches IOCP. This pass
            /// preserves notification ownership and allows even one-record short dequeues to drain.
            fn drain(self: *Runtime, record_budget: u32) void {
                var results: [types.completion_batch_size]c.RIORESULT = undefined;
                var remaining = record_budget;
                while (remaining != 0) {
                    const requested = @min(types.completion_batch_size, remaining);
                    const count = native.guards.requireDequeueCount(self.api.dequeue(self.queue.value, &results, requested), requested, "RIODequeueCompletion(UDP)");
                    if (count == 0) return;
                    remaining -= count;
                    for (results[0..count]) |result| self.processResult(result);
                }
            }

            fn completionIndex(self: *const Runtime, address: usize) u32 {
                const base = @intFromPtr(self.slots.ptr);
                const extent = self.slots.len * @sizeOf(Slot);
                const end = types.checkedAdd(usize, base, extent) orelse failFast("UDP completion identity", c.ERROR_INVALID_DATA);
                if (address < base or address >= end or (address - base) % @sizeOf(Slot) != 0) {
                    failFast("UDP completion identity", c.ERROR_INVALID_DATA);
                }
                const index: u32 = @intCast((address - base) / @sizeOf(Slot));
                if (self.provider_outstanding == 0 or self.slots[index].provider_operation == null or
                    self.provider_outstanding != self.engine_value.outstanding or
                    !self.engine_value.slots[index].outstanding or
                    self.slots[index].provider_operation.? != self.engine_value.direction(index))
                {
                    failFast("UDP completion invariant", c.ERROR_INVALID_DATA);
                }
                return index;
            }

            /// Guard is inside the release function; every initialization and terminal caller shares it.
            fn deinit(self: *Runtime) void {
                if (self.provider_outstanding != 0 or self.engine_value.outstanding != 0) failFast("UDP cleanup with outstanding operations", c.ERROR_IO_INCOMPLETE);
                for (self.slots) |slot| {
                    if (slot.provider_operation != null) failFast("UDP cleanup with outstanding operations", c.ERROR_IO_INCOMPLETE);
                }
                self.socket_owner.deinit();
                self.queue.deinit();
                self.arena_value.deinit();
                if (self.slots.len != 0) allocator.free(self.slots);
                if (self.slot_states.len != 0) allocator.free(self.slot_states);
                self.slots = &.{};
                self.slot_states = &.{};
                self.engine_value.slots = &.{};
                self.port.deinit();
            }

            fn finish(self: *Runtime, options: *const types.Options, start: u64) types.ExitCode {
                if (options.stats) {
                    var buffer: [512]u8 = undefined;
                    const line = self.engine_value.statistics.writeFinalLine(.udp, native.nowMilliseconds() - start, 1, self.engine_value.outstanding, &buffer) orelse failFast("format UDP statistics", c.ERROR_INSUFFICIENT_BUFFER);
                    _ = native.diagnostics.writeStdout(line);
                }
                const failed = self.engine_value.failed;
                self.deinit();
                native.diagnostics.writeSnapshots(&.{self.snapshot}, .udp);
                return if (failed) .network else .success;
            }
        };

        pub fn run(api: *const native.rio.Api, options: *const types.Options, stop: *std.atomic.Value(bool)) types.ExitCode {
            const capacity = options.rio_buffer_bytes;
            const stride = native.arena.udpStride(capacity) orelse {
                native.diagnostics.report("UDP slot stride", c.ERROR_NOT_ENOUGH_MEMORY);
                return .usage;
            };
            const arena_bytes = contract.checkedPageRoundedArenaBytes(options.udp_depth, stride, options.memory_bytes, native.pageBytes()) orelse 0;
            if (options.udp_depth > options.cq_capacity / 2) {
                native.diagnostics.report("UDP CQ capacity", c.ERROR_INSUFFICIENT_BUFFER);
                return .usage;
            }
            if (options.udp_depth == 0 or arena_bytes == 0 or arena_bytes > std.math.maxInt(u32)) {
                native.diagnostics.report("UDP registered arena", c.ERROR_NOT_ENOUGH_MEMORY);
                return .usage;
            }
            var value = Runtime{ .api = api, .capacity = capacity };
            defer value.deinit();
            switch (value.initialize(options, stride)) {
                .value => {},
                .failure => |failure| {
                    native.diagnostics.reportFailure(failure);
                    _ = value.engine_value.onEvent(.drained);
                    return value.finish(options, native.nowMilliseconds());
                },
            }
            for (0..options.udp_depth) |position| {
                value.execute(value.engine_value.initialPost(@intCast(position)));
                if (value.engine_value.failed) break;
            }
            const start = native.nowMilliseconds();
            value.arm();
            var results: [types.completion_batch_size]c.RIORESULT = undefined;
            var expired_packets: u32 = 0;
            while (!value.engine_value.closing or value.engine_value.hasWork()) {
                const now = native.nowMilliseconds();
                if (!value.engine_value.closing and (stop.load(.acquire) or
                    (options.run_seconds != 0 and now - start >= @as(u64, options.run_seconds) * 1000)))
                {
                    value.execute(value.engine_value.onEvent(.stop));
                }
                const drain_due = if (value.drain_started) |started|
                    now -| started >= types.drain_milliseconds
                else
                    false;
                value.arm(); // Closing cancels work; it never cancels its completion notification.
                const packet = native.rio.getQueuedCompletionStatus(value.port.get(), if (drain_due) 0 else 100);
                const queued_record = packet.ok or packet.overlapped != null or packet.key != 0;
                if (packet.overlapped == &value.notification) {
                    if (!packet.ok) failFast("GetQueuedCompletionStatus(UDP notification)", packet.native_error);
                    if (packet.key != @intFromPtr(value.slots.ptr)) failFast("UDP RIO notification key", c.ERROR_INVALID_DATA);
                    native.guards.requireTransition(contract.notificationMarkDelivered(&value.queue.armed), "UDP notification delivery transition");
                    value.snapshot.deliveries +%= 1;
                    var batches: u32 = 0;
                    while (batches < types.completion_drain_batches) : (batches += 1) {
                        const count = native.guards.requireDequeueCount(value.api.dequeue(value.queue.value, &results, types.completion_batch_size), types.completion_batch_size, "RIODequeueCompletion(UDP)");
                        if (count == 0) break;
                        for (results[0..count]) |result| value.processResult(result);
                    }
                    value.arm();
                } else if (!packet.ok and packet.native_error == c.WAIT_TIMEOUT and packet.overlapped == null) {
                    if (!value.engine_value.closing and value.engine_value.hasWork() and !value.queue.armed) value.snapshot.timeout_wakeups +%= 1;
                } else if (!packet.ok and packet.native_error != c.WAIT_TIMEOUT) {
                    failFast("GetQueuedCompletionStatus(UDP)", packet.native_error);
                } else failFast("unexpected UDP IOCP packet", c.ERROR_INVALID_DATA);
                const expired = if (value.drain_started) |started|
                    native.nowMilliseconds() - started >= types.drain_milliseconds
                else
                    false;
                if (expired and value.engine_value.hasWork()) {
                    if (queued_record and expired_packets < options.udp_depth + 1) {
                        expired_packets += 1;
                        continue;
                    }
                    value.drain(options.udp_depth);
                    value.arm();
                    if (value.engine_value.hasWork()) failFast("UDP drain deadline", c.ERROR_TIMEOUT);
                } else expired_packets = 0;
            }
            value.execute(value.engine_value.onEvent(.drained));
            if (!value.engine_value.mayRelease()) failFast("UDP release precondition", c.ERROR_INVALID_DATA);
            if (!value.snapshot.valid()) failFast("UDP notification accounting", c.ERROR_INVALID_STATE);
            return value.finish(options, start);
        }
    };
};
