const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{InvalidArguments};

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isSwitch(token: []const u8) bool {
    if (token.len < 2) return false;
    return token[0] == '/' or token[0] == '-';
}

fn parseNumber(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

pub fn parse(allocator: std.mem.Allocator, error_buffer: []u8) ParseError!types.Options {
    var args = std.process.argsWithAllocator(allocator) catch {
        setError(error_buffer, "unable to read command line");
        return error.InvalidArguments;
    };
    defer args.deinit();
    _ = args.skip();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    while (args.next()) |arg| argv.append(allocator, arg) catch {
        setError(error_buffer, "out of memory while parsing arguments");
        return error.InvalidArguments;
    };

    var out: types.Options = .{};
    var saw_timeout = false;
    var saw_udp_depth = false;
    var saw_rio_buffer = false;

    var i: usize = 0;
    while (i < argv.items.len) : (i += 1) {
        const token = argv.items[i];
        if (!isSwitch(token)) return fail(error_buffer, "server does not accept positional arguments");
        const body = if (token[0] == '-' and token.len > 1 and token[1] == '-') token[2..] else token[1..];
        const separator = std.mem.indexOfScalar(u8, body, '=');
        const name = if (separator) |p| body[0..p] else body;
        const inline_value: ?[]const u8 = if (separator) |p| body[p + 1 ..] else null;
        if (inline_value) |v| {
            if (v.len == 0) return fail(error_buffer, "switch requires a non-empty inline value");
        }

        if (eq(name, "q") or eq(name, "quiet") or eq(name, "stats") or eq(name, "h") or eq(name, "help")) {
            if (inline_value != null) return fail(error_buffer, "flag switch does not accept a value");
            if (eq(name, "q") or eq(name, "quiet")) out.quiet = true;
            if (eq(name, "stats")) out.stats = true;
            if (eq(name, "h") or eq(name, "help")) out.help = true;
            continue;
        }

        const known = eq(name, "p") or eq(name, "s") or eq(name, "t") or eq(name, "w") or eq(name, "b") or
            eq(name, "k") or eq(name, "threads") or eq(name, "rio-buffer") or eq(name, "cq") or eq(name, "memory");
        if (!known) return fail(error_buffer, "unknown switch");

        const value = inline_value orelse blk: {
            if (i + 1 >= argv.items.len or isSwitch(argv.items[i + 1])) return fail(error_buffer, "switch requires a non-empty value");
            i += 1;
            break :blk argv.items[i];
        };

        if (eq(name, "p")) {
            if (eq(value, "tcp")) {
                out.protocol = .tcp;
            } else if (eq(value, "udp")) {
                out.protocol = .udp;
            } else {
                return fail(error_buffer, "/p requires tcp or udp");
            }
            continue;
        }

        const n = parseNumber(value) orelse return fail(error_buffer, "numeric switch has an invalid value");
        if (eq(name, "s") and n >= 1 and n <= 65535) {
            out.port = @intCast(n);
        } else if (eq(name, "t") and n >= 1 and n <= std.math.maxInt(u32)) {
            out.timeout_seconds = @intCast(n);
            saw_timeout = true;
        } else if (eq(name, "w") and n >= 1 and n <= std.math.maxInt(u32)) {
            out.run_seconds = @intCast(n);
        } else if (eq(name, "b") and n <= @as(u64, std.math.maxInt(i32))) {
            out.socket_buffer_bytes = @intCast(n);
        } else if (eq(name, "k") and n >= 1 and n <= 65536) {
            out.udp_depth = @intCast(n);
            saw_udp_depth = true;
        } else if (eq(name, "threads") and n >= 1 and n <= 64) {
            out.worker_count = @intCast(n);
        } else if (eq(name, "rio-buffer") and n >= 512 and n <= 1048576) {
            out.rio_buffer_bytes = @intCast(n);
            saw_rio_buffer = true;
        } else if (eq(name, "cq") and n >= 64 and n <= 1048576) {
            out.cq_capacity = @intCast(n);
        } else if (eq(name, "memory") and n >= 1048576) {
            out.memory_bytes = n;
        } else {
            return fail(error_buffer, "unknown switch or value outside its valid range");
        }
    }

    if (out.help) return out;
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
    return out;
}

fn setError(buffer: []u8, message: []const u8) void {
    if (buffer.len == 0) return;
    const n = @min(buffer.len - 1, message.len);
    @memcpy(buffer[0..n], message[0..n]);
    buffer[n] = 0;
}

fn fail(buffer: []u8, message: []const u8) ParseError {
    setError(buffer, message);
    return error.InvalidArguments;
}
