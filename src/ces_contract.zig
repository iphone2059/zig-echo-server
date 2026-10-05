//! The server binary's contract, in one place: the command line (switches, ranges, diagnostic
//! tokens, usage text) and the contract helpers the engine needs, mirroring the reference's single
//! contract file.
//!
//! Reference implementation: echo-binary-contract-v1 (the C++ server).

pub const version = "echo-binary-contract-v1";

/// The value switches this server accepts, as compile-time data: the parser asks the table instead
/// of spelling every switch name out at each use, so the accepted set lives in exactly one place.
/// Which protocol a switch belongs to; the parser rejects a switch used with the wrong one.
pub const Scope = enum { both, tcp_only, udp_only };

pub const Switch = struct {
    name: []const u8,
    minimum: u64,
    maximum: u64,
    scope: Scope,
};

pub const switch_table = [_]Switch{
    .{ .name = "p", .minimum = 0, .maximum = 0, .scope = .both },
    .{ .name = "s", .minimum = 1, .maximum = 65535, .scope = .both },
    .{ .name = "t", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .tcp_only },
    .{ .name = "w", .minimum = 1, .maximum = std.math.maxInt(u32), .scope = .both },
    .{ .name = "b", .minimum = 0, .maximum = std.math.maxInt(i32), .scope = .both },
    .{ .name = "k", .minimum = 1, .maximum = 65536, .scope = .udp_only },
    .{ .name = "threads", .minimum = 1, .maximum = 64, .scope = .both },
    .{ .name = "rio-buffer", .minimum = 512, .maximum = 1048576, .scope = .both },
    .{ .name = "cq", .minimum = 64, .maximum = 1048576, .scope = .both },
    .{ .name = "memory", .minimum = 1048576, .maximum = std.math.maxInt(u64), .scope = .both },
};

comptime {
    if (switchInfo("t").?.scope != .tcp_only) @compileError("switch t must stay TCP only");
    if (switchInfo("k").?.scope != .udp_only) @compileError("switch k must stay UDP only");
}
/// Compile-time lookup: the compiler unrolls the table, so a typo here is a build error.
pub fn switchInfo(name: []const u8) ?Switch {
    inline for (switch_table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry.name)) return entry;
    }
    return null;
}


/// Diagnostic tokens.
pub const tokens = struct {
    pub const protocol_option = "protocol-option";
    pub const invalid_number = "invalid-number";
    pub const out_of_range = "out-of-range";
    pub const unknown_switch = "unknown-switch";
};

/// Usage text.
pub const usage =
    "Usage: zig-echo-server /p tcp|udp [/s port] [/t seconds] [/w seconds]\n" ++
    "       [/b bytes] [/k udp-depth] [/threads workers] [/rio-buffer bytes]\n" ++
    "       [/cq capacity] [/memory bytes] [/q] [/stats]\n" ++
    "Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.\n";

const std = @import("std");

pub fn checkedProduct(left: usize, right: usize) ?usize {
    const pair = @mulWithOverflow(left, right);
    if (pair[1] != 0) return null;
    return pair[0];
}

pub fn checkedArenaBytes(slots: usize, stride: usize, memory_limit: u64) ?usize {
    const bytes = checkedProduct(slots, stride) orelse return null;
    if (bytes > memory_limit) return null;
    return bytes;
}

pub fn tcpConnectionCapacity(cq_capacity: u32, memory_slots: u64) u32 {
    const cq_slots: u64 = cq_capacity / 2;
    const limit = @min(cq_slots, memory_slots);
    return @intCast(@min(limit, std.math.maxInt(u32)));
}

pub fn advanceOffset(total: usize, transferred: usize, offset: *usize) bool {
    if (transferred == 0 or offset.* > total or transferred > total - offset.*) return false;
    offset.* += transferred;
    return true;
}

pub fn notificationMarkDelivered(armed: *bool) bool {
    if (!armed.*) return false;
    armed.* = false;
    return true;
}

pub fn notificationMarkRearmed(armed: *bool) bool {
    if (armed.*) return false;
    armed.* = true;
    return true;
}

test "checked arithmetic" {
    try std.testing.expectEqual(@as(?usize, 42), checkedProduct(6, 7));
    try std.testing.expect(checkedProduct(std.math.maxInt(usize), 2) == null);
    try std.testing.expectEqual(@as(?usize, 4096), checkedArenaBytes(4, 1024, 4096));
    try std.testing.expect(checkedArenaBytes(4, 1024, 4095) == null);
}

test "notification transitions" {
    var armed = false;
    try std.testing.expect(notificationMarkRearmed(&armed));
    try std.testing.expect(!notificationMarkRearmed(&armed));
    try std.testing.expect(notificationMarkDelivered(&armed));
    try std.testing.expect(!notificationMarkDelivered(&armed));
}

const types = @import("types.zig");

fn equalAsciiFold(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        const folded_a = if (a >= 'A' and a <= 'Z') a + ('a' - 'A') else a;
        const folded_b = if (b >= 'A' and b <= 'Z') b + ('a' - 'A') else b;
        if (folded_a != folded_b) return false;
    }
    return true;
}

fn isSwitch(token: []const u8) bool {
    if (token.len < 2 or (token[0] != '/' and token[0] != '-')) return false;
    const offset: usize = if (token.len > 2 and token[0] == '-' and token[1] == '-') 2 else 1;
    if (offset >= token.len) return false;
    const first = if (token[offset] >= 'A' and token[offset] <= 'Z') token[offset] + ('a' - 'A') else token[offset];
    return first >= 'a' and first <= 'z';
}

fn isKnownValueSwitch(name: []const u8) bool {
    return switchInfo(name) != null;
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

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (!isSwitch(token)) return fail(error_buffer, "server does not accept positional arguments");
        const offset: usize = if (token.len > 1 and token[0] == '-' and token[1] == '-') 2 else 1;
        const body = token[offset..];
        const separator = std.mem.indexOfScalar(u8, body, '=');
        const name = if (separator) |position| body[0..position] else body;
        const inline_value = if (separator) |position| body[position + 1 ..] else "";
        if (separator != null and inline_value.len == 0)
            return fail(error_buffer, "switch requires a non-empty inline value");

        if (equalAsciiFold(name, "q") or equalAsciiFold(name, "quiet") or equalAsciiFold(name, "stats") or
            equalAsciiFold(name, "h") or equalAsciiFold(name, "help"))
        {
            if (separator != null) return fail(error_buffer, "flag switch does not accept a value");
            out.quiet = out.quiet or equalAsciiFold(name, "q") or equalAsciiFold(name, "quiet");
            out.stats = out.stats or equalAsciiFold(name, "stats");
            out.help = out.help or equalAsciiFold(name, "h") or equalAsciiFold(name, "help");
            continue;
        }

        if (!isKnownValueSwitch(name)) return fail(error_buffer, tokens.unknown_switch);
        const value: []const u8 = if (separator != null)
            inline_value
        else value_block: {
            if (index + 1 >= argv.len or isSwitch(argv[index + 1]))
                return fail(error_buffer, "switch requires a non-empty value");
            index += 1;
            if (argv[index].len == 0) return fail(error_buffer, "switch requires a non-empty value");
            break :value_block argv[index];
        };

        if (equalAsciiFold(name, "p")) {
            if (equalAsciiFold(value, "tcp")) {
                out.protocol = .tcp;
            } else if (equalAsciiFold(value, "udp")) {
                out.protocol = .udp;
            } else {
                return fail(error_buffer, "/p requires tcp or udp");
            }
            continue;
        }

        const number = parseNumber(value) orelse return fail(error_buffer, tokens.invalid_number);
        const info = switchInfo(name) orelse return fail(error_buffer, tokens.unknown_switch);
        if (number < info.minimum or number > info.maximum) return fail(error_buffer, tokens.out_of_range);
        if (equalAsciiFold(name, "s") and number >= 1 and number <= 65535) {
            out.port = @intCast(number);
        } else if (equalAsciiFold(name, "t") and number >= 1 and number <= std.math.maxInt(u32)) {
            out.timeout_seconds = @intCast(number);
            saw_timeout = true;
        } else if (equalAsciiFold(name, "w") and number >= 1 and number <= std.math.maxInt(u32)) {
            out.run_seconds = @intCast(number);
        } else if (equalAsciiFold(name, "b") and number <= std.math.maxInt(i32)) {
            out.socket_buffer_bytes = @intCast(number);
        } else if (equalAsciiFold(name, "k") and number >= 1 and number <= 65536) {
            out.udp_depth = @intCast(number);
            saw_udp_depth = true;
        } else if (equalAsciiFold(name, "threads") and number >= 1 and number <= 64) {
            out.worker_count = @intCast(number);
        } else if (equalAsciiFold(name, "rio-buffer") and number >= 512 and number <= 1048576) {
            out.rio_buffer_bytes = @intCast(number);
            saw_rio_buffer = true;
        } else if (equalAsciiFold(name, "cq") and number >= 64 and number <= 1048576) {
            out.cq_capacity = @intCast(number);
        } else if (equalAsciiFold(name, "memory") and number >= 1048576) {
            out.memory_bytes = number;
        } else {
            return fail(error_buffer, tokens.out_of_range);
        }
    }

    if (out.protocol == .tcp and saw_udp_depth) return fail(error_buffer, tokens.protocol_option);
    if (out.protocol == .udp and saw_timeout) return fail(error_buffer, tokens.protocol_option);
    if (out.help) return true;
    if (out.protocol == .none) return fail(error_buffer, "missing /p tcp or /p udp");
    if (out.protocol == .udp) {
        if (!saw_rio_buffer) {
            out.rio_buffer_bytes = types.max_udp_payload;
        } else if (out.rio_buffer_bytes < types.max_udp_payload) {
            return fail(error_buffer, "UDP /rio-buffer must be at least 65507 bytes");
        }
    }
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