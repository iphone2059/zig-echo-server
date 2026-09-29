const std = @import("std");
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
    return equalAsciiFold(name, "p") or equalAsciiFold(name, "s") or equalAsciiFold(name, "t") or
        equalAsciiFold(name, "w") or equalAsciiFold(name, "b") or equalAsciiFold(name, "k") or
        equalAsciiFold(name, "threads") or equalAsciiFold(name, "rio-buffer") or
        equalAsciiFold(name, "cq") or equalAsciiFold(name, "memory");
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

        if (!isKnownValueSwitch(name)) return fail(error_buffer, "unknown switch");
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

        const number = parseNumber(value) orelse return fail(error_buffer, "numeric switch has an invalid value");
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
            return fail(error_buffer, "unknown switch or value outside its valid range");
        }
    }

    if (out.help) return true;
    if (out.protocol == .none) return fail(error_buffer, "missing /p tcp or /p udp");
    if (out.protocol == .tcp and saw_udp_depth) return fail(error_buffer, "/k is available only for UDP");
    if (out.protocol == .udp and saw_timeout) return fail(error_buffer, "/t is available only for TCP");
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
