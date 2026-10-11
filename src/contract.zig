//! The server binary's contract, in one place: the command line (switches, ranges, diagnostic
//! tokens, usage text), the capacity budgets and the shared classification helpers.
//!
//! Reference implementation: echo-binary-contract-v1 (the C++ server). The parser reproduces the
//! reference's token-consumption order, its diagnostic precedence and its capacity rules, so a
//! command line produces the same diagnostic in every implementation.

const std = @import("std");
const native = @import("native.zig");
const types = @import("types.zig");

/// Identifier of the frozen binary contract this file implements.
pub const version = "echo-binary-contract-v1";

/// Diagnostic tokens that must follow "Invalid arguments: " on stderr.
pub const tokens = struct {
    pub const protocol_option = "protocol-option";
    pub const invalid_number = "invalid-number";
    pub const out_of_range = "out-of-range";
    pub const unknown_switch = "unknown-switch";
    pub const unexpected_value = "unexpected-value";
    pub const missing_value = "missing-value";
    pub const missing_protocol = "missing-protocol";
    pub const unexpected_target = "unexpected-target";
    pub const payload_size = "payload-size";
    pub const cq_capacity = "cq-capacity";
    pub const memory_capacity = "memory-capacity";
    pub const invalid_utf16 = "invalid-utf16";
};

/// Usage text, printed on stdout for a valid help command line and on stderr for a usage error.
pub const usage =
    "Usage: zig-echo-server /p tcp|udp [/s port] [/t seconds] [/w seconds]\n" ++
    "       [/b bytes] [/k udp-depth] [/threads workers] [/rio-buffer bytes]\n" ++
    "       [/cq capacity] [/memory bytes] [/q] [/stats]\n" ++
    "Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.\n";

/// Which protocol a switch belongs to; the parser rejects a switch used with the wrong one.
pub const Scope = enum { both, tcp_only, udp_only };

pub const Switch = struct {
    name: []const u8,
    minimum: u64,
    maximum: u64,
    scope: Scope,
};

/// The value switches this server accepts, as compile-time data. An explicit zero is valid
/// wherever the reference accepts one: the run duration means "no deadline" and the worker count
/// means "automatic".
pub const switch_table = [_]Switch{
    .{ .name = "p", .minimum = 0, .maximum = 0, .scope = .both },
    .{ .name = "s", .minimum = 1, .maximum = 65_535, .scope = .both },
    .{ .name = "t", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .tcp_only },
    .{ .name = "w", .minimum = 0, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "b", .minimum = 0, .maximum = 2_147_483_647, .scope = .both },
    .{ .name = "k", .minimum = 1, .maximum = 65_536, .scope = .udp_only },
    .{ .name = "threads", .minimum = 0, .maximum = types.maximum_workers, .scope = .both },
    .{ .name = "rio-buffer", .minimum = 512, .maximum = 1_048_576, .scope = .both },
    .{ .name = "cq", .minimum = 64, .maximum = 1_048_576, .scope = .both },
    .{ .name = "memory", .minimum = 1_048_576, .maximum = std.math.maxInt(u64), .scope = .both },
};

comptime {
    // The timeout switch is TCP only and the datagram depth is UDP only: the cross-field rules
    // report both under the protocol-option token, so the table and those rules may never disagree.
    if (switchInfo("t").?.scope != .tcp_only) @compileError("switch t must stay TCP only");
    if (switchInfo("k").?.scope != .udp_only) @compileError("switch k must stay UDP only");
    if (switchInfo("w").?.minimum != 0) @compileError("explicit /w 0 must stay valid");
    if (switchInfo("threads").?.minimum != 0) @compileError("explicit /threads 0 must stay valid");
    // The bounded accept window and the UDP address charge are contract constants, not tunables.
    if (acceptOperationCount(0) != 8) @compileError("the accept window has a floor of eight");
    if (acceptOperationCount(types.maximum_workers) != 128) @compileError("the accept window caps at 128");
    if (types.udp_address_bytes != 144) @compileError("a UDP slot charges 144 address bytes");
}

/// Compile-time lookup: the table is unrolled by the compiler, so a typo here is a build error.
pub fn switchInfo(name: []const u8) ?Switch {
    inline for (switch_table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry;
    }
    return null;
}

pub const checkedProduct = types.checkedProduct;
pub const ceilingDivide = types.ceilingDivide;

pub fn checkedArenaBytes(slots: u64, stride: u64, memory_limit: u64) ?u64 {
    const bytes = types.checkedProduct(u64, slots, stride) orelse return null;
    return if (bytes <= memory_limit) bytes else null;
}

/// Keeps the logical slot length while charging the actual page-rounded allocation, so a budget
/// that cannot hold the rounded pages is refused even though the logical bytes would fit.
pub fn checkedPageRoundedArenaBytes(slots: u64, stride: u64, memory_limit: u64, page: u64) ?u64 {
    if (page == 0) return null;
    const bytes = types.checkedProduct(u64, slots, stride) orelse return null;
    const remainder = bytes % page;
    const allocated = if (remainder == 0) bytes else (types.checkedAdd(u64, bytes, page - remainder) orelse return null);
    return if (allocated <= memory_limit) bytes else null;
}

/// One worker's share of the memory budget, rounded down to whole pages with the remainder handed
/// to the first workers.
pub fn workerMemoryBudget(memory_bytes: u64, worker_count: u32, worker_index: u32, page: u64) u64 {
    if (worker_count == 0 or page == 0) return 0;
    const pages = memory_bytes / page;
    const share = pages / worker_count;
    const extra = @intFromBool(worker_index < pages % worker_count);
    return (share + extra) * page;
}

pub fn tcpConnectionCapacity(cq_capacity: u32, memory_slots: u64) u32 {
    const queue_slots: u64 = cq_capacity / 2;
    const bounded = @min(queue_slots, memory_slots);
    return @intCast(@min(bounded, std.math.maxInt(u32)));
}

pub fn advanceOffset(total: usize, transferred: usize, offset: *usize) bool {
    if (transferred == 0 or offset.* > total or transferred > total - offset.*) return false;
    offset.* += transferred;
    return true;
}

/// The same rule for the 32-bit byte counters a connection record keeps: a zero-byte transfer or
/// one that would run past the total is refused and the offset is left untouched.
pub fn advanceOffsetU32(total: u32, transferred: u32, offset: *u32) bool {
    if (transferred == 0 or offset.* > total or transferred > total - offset.*) return false;
    offset.* += transferred;
    return true;
}

/// One CQ notification is in flight at a time. A delivery consumes the armed state, so a second
/// delivery for the same registration is an invariant violation rather than a no-op.
pub fn notificationMarkDelivered(armed: *bool) bool {
    if (!armed.*) return false;
    armed.* = false;
    return true;
}

/// The drain finished and the queue is armed again. Arming twice without a delivery in between is
/// refused for the same reason.
pub fn notificationMarkRearmed(armed: *bool) bool {
    if (armed.*) return false;
    armed.* = true;
    return true;
}

/// Identity of an IOCP packet: the completion key and the OVERLAPPED address must both match the
/// registration, which is what keeps an unrelated packet from being treated as this queue's
/// notification. Addresses are compared as integers so the check is testable without native
/// storage.
pub fn notificationPacketMatches(key: usize, overlapped: usize, expected_key: usize, expected_overlapped: usize) bool {
    return key == expected_key and overlapped == expected_overlapped;
}

/// The bounded accept window: two operations per worker, at least eight and at most 128.
pub fn acceptOperationCount(worker_count: u32) u32 {
    const doubled = types.checkedProduct(u32, worker_count, 2) orelse std.math.maxInt(u32);
    return std.math.clamp(doubled, 8, 128);
}

/// Windows supplies command-line arguments as WTF-8, where an unpaired surrogate is a three-byte
/// sequence starting with 0xED. A valid pair is always a single four-byte sequence, so this pattern
/// can only ever be a lone surrogate.
fn hasLoneSurrogate(bytes: []const u8) bool {
    var index: usize = 0;
    while (index + 2 < bytes.len) : (index += 1) {
        if (bytes[index] == 0xED and bytes[index + 1] >= 0xA0 and bytes[index + 1] <= 0xBF) return true;
    }
    return false;
}

fn isSwitch(token: []const u8) bool {
    if (token.len < 2 or (token[0] != '/' and token[0] != '-')) return false;
    const offset: usize = if (token.len > 2 and token[0] == '-' and token[1] == '-') 2 else 1;
    if (offset >= token.len) return false;
    return std.ascii.isAlphabetic(token[offset]);
}

fn setError(buffer: []u8, message: []const u8) void {
    if (buffer.len == 0) return;
    const count = @min(buffer.len - 1, message.len);
    @memcpy(buffer[0..count], message[0..count]);
    buffer[count] = 0;
}

fn fail(buffer: []u8, message: []const u8) bool {
    setError(buffer, message);
    return false;
}

fn parseNumber(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var value: u64 = 0;
    for (text) |character| {
        if (character < '0' or character > '9') return null;
        const digit: u64 = character - '0';
        if (value > (std.math.maxInt(u64) - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return value;
}

pub fn parseArgs(argv: []const []const u8, out: *types.Options, error_buffer: []u8) bool {
    if (argv.len < 1) return fail(error_buffer, "invalid parser arguments");
    out.* = .{};
    var saw_timeout = false;
    var saw_udp_depth = false;
    var saw_rio_buffer = false;
    var saw_workers = false;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (hasLoneSurrogate(token)) return fail(error_buffer, tokens.invalid_utf16);
        if (!isSwitch(token)) return fail(error_buffer, tokens.unexpected_target);
        const offset: usize = if (token.len > 1 and token[0] == '-' and token[1] == '-') 2 else 1;
        const body = token[offset..];
        const separator = std.mem.indexOfScalar(u8, body, '=');
        const name = if (separator) |position| body[0..position] else body;
        const inline_value: ?[]const u8 = if (separator) |position| body[position + 1 ..] else null;

        if (std.ascii.eqlIgnoreCase(name, "q") or std.ascii.eqlIgnoreCase(name, "quiet") or
            std.ascii.eqlIgnoreCase(name, "stats") or std.ascii.eqlIgnoreCase(name, "h") or
            std.ascii.eqlIgnoreCase(name, "help"))
        {
            // A flag never takes a value, and an empty one is still a value.
            if (inline_value != null) return fail(error_buffer, tokens.unexpected_value);
            out.quiet = out.quiet or std.ascii.eqlIgnoreCase(name, "q") or std.ascii.eqlIgnoreCase(name, "quiet");
            out.stats = out.stats or std.ascii.eqlIgnoreCase(name, "stats");
            out.help = out.help or std.ascii.eqlIgnoreCase(name, "h") or std.ascii.eqlIgnoreCase(name, "help");
            continue;
        }

        if (switchInfo(name) == null) return fail(error_buffer, tokens.unknown_switch);
        const value: []const u8 = if (inline_value) |written| value_block: {
            if (written.len == 0) return fail(error_buffer, tokens.missing_value);
            break :value_block written;
        } else value_block: {
            // A value may not be absent, empty, or shaped like another switch.
            if (index + 1 >= argv.len or argv[index + 1].len == 0 or isSwitch(argv[index + 1])) {
                return fail(error_buffer, tokens.missing_value);
            }
            index += 1;
            if (hasLoneSurrogate(argv[index])) return fail(error_buffer, tokens.invalid_utf16);
            break :value_block argv[index];
        };

        if (std.ascii.eqlIgnoreCase(name, "p")) {
            // The reference matches the protocol keyword itself and reports the parse failure as an
            // out-of-range value, not as a protocol-specific message.
            if (std.ascii.eqlIgnoreCase(value, "tcp")) {
                out.protocol = .tcp;
            } else if (std.ascii.eqlIgnoreCase(value, "udp")) {
                out.protocol = .udp;
            } else {
                return fail(error_buffer, tokens.out_of_range);
            }
            continue;
        }

        const number = parseNumber(value) orelse return fail(error_buffer, tokens.invalid_number);
        const info = switchInfo(name) orelse return fail(error_buffer, tokens.unknown_switch);
        if (number < info.minimum or number > info.maximum) return fail(error_buffer, tokens.out_of_range);
        if (std.ascii.eqlIgnoreCase(name, "s")) {
            out.port = @intCast(number);
        } else if (std.ascii.eqlIgnoreCase(name, "t")) {
            out.timeout_seconds = @intCast(number);
            saw_timeout = true;
        } else if (std.ascii.eqlIgnoreCase(name, "w")) {
            out.run_seconds = @intCast(number);
        } else if (std.ascii.eqlIgnoreCase(name, "b")) {
            out.socket_buffer_bytes = @intCast(number);
        } else if (std.ascii.eqlIgnoreCase(name, "k")) {
            out.udp_depth = @intCast(number);
            saw_udp_depth = true;
        } else if (std.ascii.eqlIgnoreCase(name, "threads")) {
            out.worker_count = @intCast(number);
            saw_workers = true;
        } else if (std.ascii.eqlIgnoreCase(name, "rio-buffer")) {
            out.rio_buffer_bytes = @intCast(number);
            saw_rio_buffer = true;
        } else if (std.ascii.eqlIgnoreCase(name, "cq")) {
            out.cq_capacity = @intCast(number);
        } else if (std.ascii.eqlIgnoreCase(name, "memory")) {
            out.memory_bytes = number;
        } else {
            return fail(error_buffer, tokens.unknown_switch);
        }
    }

    // A switch used with the wrong protocol is reported before any capacity rule.
    if (out.protocol == .tcp and saw_udp_depth) return fail(error_buffer, tokens.protocol_option);
    if (out.protocol == .udp and saw_timeout) return fail(error_buffer, tokens.protocol_option);
    // The datagram path is single-threaded in the reference whatever the worker switch says.
    if (out.protocol == .udp and saw_workers and out.worker_count > 1) return fail(error_buffer, tokens.protocol_option);

    // Capacity is validated before the help short-circuit, exactly like the reference: help never
    // masks a budget the run could not satisfy, only the mandatory-protocol check.
    if (out.protocol == .udp) {
        out.worker_count = 1;
        if (!saw_rio_buffer) {
            // UDP defaults to one maximum-sized datagram per slot; the depth keeps its own default.
            out.rio_buffer_bytes = @intCast(types.maximum_udp_payload);
        } else if (out.rio_buffer_bytes < types.maximum_udp_payload) {
            return fail(error_buffer, tokens.payload_size);
        }
        // Each datagram slot reserves a queue entry per direction.
        if (out.udp_depth > out.cq_capacity / 2) return fail(error_buffer, tokens.cq_capacity);
        const stride = types.checkedAdd(u64, out.rio_buffer_bytes, types.udp_address_bytes) orelse
            return fail(error_buffer, tokens.memory_capacity);
        const bytes = checkedPageRoundedArenaBytes(out.udp_depth, stride, out.memory_bytes, native.pageBytes()) orelse
            return fail(error_buffer, tokens.memory_capacity);
        if (bytes > std.math.maxInt(u32)) return fail(error_buffer, tokens.memory_capacity);
    }
    if (out.protocol == .tcp) {
        // Every worker needs a page-rounded share of the memory budget that can hold at least one
        // slot; otherwise it cannot register its arena at all.
        const workers = if (out.worker_count == 0)
            types.resolvedWorkerCount(out.worker_count, native.activeProcessorCount())
        else
            out.worker_count;
        const page = native.pageBytes();
        var worker_index: u32 = 0;
        while (worker_index < workers) : (worker_index += 1) {
            const budget = workerMemoryBudget(out.memory_bytes, workers, worker_index, page);
            const slots = @min(@as(u64, out.cq_capacity / 2), budget / out.rio_buffer_bytes);
            if (slots == 0) return fail(error_buffer, tokens.memory_capacity);
        }
    }

    if (out.help) return true;
    if (out.protocol == .none) return fail(error_buffer, tokens.missing_protocol);
    return true;
}

pub fn parseProcessArgs(
    args: std.process.Args,
    allocator: std.mem.Allocator,
    out: *types.Options,
    error_buffer: []u8,
) bool {
    var iterator = args.iterateAllocator(allocator) catch return fail(error_buffer, "unable to read command line");
    defer iterator.deinit();
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |argument| allocator.free(argument);
        owned.deinit(allocator);
    }
    while (iterator.next()) |argument| {
        const copy = allocator.dupe(u8, argument) catch return fail(error_buffer, "out of memory while parsing arguments");
        owned.append(allocator, copy) catch {
            allocator.free(copy);
            return fail(error_buffer, "out of memory while parsing arguments");
        };
    }
    return parseArgs(owned.items, out, error_buffer);
}

test "checked arithmetic and page rounding" {
    try std.testing.expectEqual(@as(?u64, 42), checkedProduct(u64, 6, 7));
    try std.testing.expect(checkedProduct(u64, std.math.maxInt(u64), 2) == null);
    try std.testing.expectEqual(@as(?u64, 4096), checkedArenaBytes(4, 1024, 4096));
    try std.testing.expect(checkedArenaBytes(4, 1024, 4095) == null);
    // 5 slots of 1000 logical bytes need 8192 allocated bytes, which exceeds a 4096 budget.
    try std.testing.expectEqual(@as(?u64, 5000), checkedPageRoundedArenaBytes(5, 1000, 8192, 4096));
    try std.testing.expect(checkedPageRoundedArenaBytes(5, 1000, 4096, 4096) == null);
    try std.testing.expect(checkedPageRoundedArenaBytes(5, 1000, 8192, 0) == null);
    // The logical length is preserved even though the charge is rounded.
    try std.testing.expectEqual(@as(?u64, 4096), checkedPageRoundedArenaBytes(4, 1024, 4096, 4096));
}

test "the memory budget is page rounded and the remainder goes to the first workers" {
    try std.testing.expectEqual(@as(u64, 4096), workerMemoryBudget(8192, 2, 0, 4096));
    try std.testing.expectEqual(@as(u64, 4096), workerMemoryBudget(8192, 2, 1, 4096));
    // Three pages over two workers: the first gets two, the second one.
    try std.testing.expectEqual(@as(u64, 8192), workerMemoryBudget(12_288, 2, 0, 4096));
    try std.testing.expectEqual(@as(u64, 4096), workerMemoryBudget(12_288, 2, 1, 4096));
    try std.testing.expectEqual(@as(u64, 0), workerMemoryBudget(12_288, 0, 0, 4096));
}

test "the accept window is bounded like the baseline" {
    try std.testing.expectEqual(@as(u32, 8), acceptOperationCount(0));
    try std.testing.expectEqual(@as(u32, 8), acceptOperationCount(1));
    try std.testing.expectEqual(@as(u32, 8), acceptOperationCount(4));
    try std.testing.expectEqual(@as(u32, 10), acceptOperationCount(5));
    try std.testing.expectEqual(@as(u32, 128), acceptOperationCount(64));
    try std.testing.expectEqual(@as(u32, 128), acceptOperationCount(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 64), tcpConnectionCapacity(128, 1000));
    try std.testing.expectEqual(@as(u32, 10), tcpConnectionCapacity(4096, 10));
}

test "send progression is checked like the baseline" {
    var offset: u32 = 0;
    try std.testing.expect(advanceOffsetU32(10, 4, &offset));
    try std.testing.expectEqual(@as(u32, 4), offset);
    try std.testing.expect(!advanceOffsetU32(10, 0, &offset));
    try std.testing.expect(!advanceOffsetU32(10, 7, &offset));
    try std.testing.expect(advanceOffsetU32(10, 6, &offset));
    try std.testing.expectEqual(@as(u32, 10), offset);
    var wide: usize = 0;
    try std.testing.expect(advanceOffset(8, 8, &wide));
    try std.testing.expect(!advanceOffset(8, 1, &wide));
}

test "notification transitions are one shot and identity needs both fields" {
    var armed = false;
    try std.testing.expect(notificationMarkRearmed(&armed));
    try std.testing.expect(!notificationMarkRearmed(&armed));
    try std.testing.expect(notificationMarkDelivered(&armed));
    try std.testing.expect(!notificationMarkDelivered(&armed));
    try std.testing.expect(notificationPacketMatches(7, 9, 7, 9));
    try std.testing.expect(!notificationPacketMatches(7, 8, 7, 9));
    try std.testing.expect(!notificationPacketMatches(6, 9, 7, 9));
}
