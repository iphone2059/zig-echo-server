const std = @import("std");
const server = @import("server");
const types = server.types;
const options_mod = server.options;
const contract = server.contract;

fn parse(argv: []const []const u8, out: *types.Options, error_buffer: []u8) bool {
    @memset(error_buffer, 0);
    return options_mod.parseArgs(argv, out, error_buffer);
}

fn errorText(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

test "server defaults and exit codes match C++" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/p", "tcp" }, &options, &error_buffer));
    try std.testing.expectEqual(types.Protocol.tcp, options.protocol);
    try std.testing.expectEqual(@as(u16, 7), options.port);
    try std.testing.expectEqual(@as(u32, 300), options.timeout_seconds);
    try std.testing.expectEqual(@as(u32, 0), options.run_seconds);
    try std.testing.expectEqual(@as(u32, 0), options.socket_buffer_bytes);
    try std.testing.expectEqual(@as(u32, 256), options.udp_depth);
    try std.testing.expectEqual(@as(u32, 0), options.worker_count);
    try std.testing.expectEqual(@as(u32, 16384), options.rio_buffer_bytes);
    try std.testing.expectEqual(@as(u32, 4096), options.cq_capacity);
    try std.testing.expectEqual(@as(u64, 1073741824), options.memory_bytes);
    try std.testing.expect(!options.quiet and !options.stats and !options.help);
    try std.testing.expectEqual(@as(u8, 0), @backingInt(types.ExitCode.success));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(types.ExitCode.internal));
}

test "help bypasses protocol requirement but not malformed neighbors" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/h" }, &options, &error_buffer));
    try std.testing.expect(options.help);
    try std.testing.expect(!parse(&.{ "server", "/h", "/s=" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("switch requires a non-empty inline value", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/help", "/p", "invalid" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("/p requires tcp or udp", errorText(&error_buffer));
}

test "switch classification and values are ASCII exact" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/P", "TcP", "--S=7000", "-Q", "/StAtS" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u16, 7000), options.port);
    try std.testing.expect(options.quiet and options.stats);
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "/1" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("numeric switch has an invalid value", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("switch requires a non-empty value", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/quiet=yes" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("flag switch does not accept a value", errorText(&error_buffer));
}

test "protocol-specific switches and UDP promotion match C++" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/k", "2" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("/k is available only for UDP", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "udp", "/t", "2" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("/t is available only for TCP", errorText(&error_buffer));
    try std.testing.expect(parse(&.{ "server", "/p", "udp" }, &options, &error_buffer));
    try std.testing.expectEqual(types.max_udp_payload, options.rio_buffer_bytes);
    try std.testing.expect(!parse(&.{ "server", "/p", "udp", "/rio-buffer", "65506" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("UDP /rio-buffer must be at least 65507 bytes", errorText(&error_buffer));
    try std.testing.expect(parse(&.{ "server", "/p", "udp", "/rio-buffer", "65507" }, &options, &error_buffer));
}

test "all numeric boundaries and error categories match C++" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/p", "tcp", "/s", "1", "/t", "4294967295", "/w", "4294967295", "/b", "2147483647", "/threads", "64", "/rio-buffer", "1048576", "/cq", "1048576", "/memory", "1048576" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u32, 64), options.worker_count);
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "0" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("unknown switch or value outside its valid range", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/cq", "63" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/memory", "1048575" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "18446744073709551616" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("numeric switch has an invalid value", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/foo", "bar" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("unknown switch", errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "tcp" }, &options, &error_buffer));
    try std.testing.expectEqualStrings("server does not accept positional arguments", errorText(&error_buffer));
}

test "capacity partial-send and notification contracts match C++" {
    try std.testing.expectEqual(@as(?usize, 4194304), contract.checkedProduct(1024, 4096));
    try std.testing.expect(contract.checkedProduct(std.math.maxInt(usize), 2) == null);
    try std.testing.expect(contract.checkedArenaBytes(1024, 65536, 1024) == null);
    try std.testing.expectEqual(@as(u32, 512), contract.tcpConnectionCapacity(1024, 800));
    try std.testing.expectEqual(@as(u32, 300), contract.tcpConnectionCapacity(1024, 300));

    var offset: usize = 4;
    try std.testing.expect(contract.advanceOffset(10, 3, &offset));
    try std.testing.expectEqual(@as(usize, 7), offset);
    try std.testing.expect(!contract.advanceOffset(10, 0, &offset));
    try std.testing.expect(!contract.advanceOffset(10, 4, &offset));

    var armed = true;
    try std.testing.expect(contract.notificationMarkDelivered(&armed));
    try std.testing.expect(!contract.notificationMarkDelivered(&armed));
    try std.testing.expect(contract.notificationMarkRearmed(&armed));
    try std.testing.expect(!contract.notificationMarkRearmed(&armed));
}
