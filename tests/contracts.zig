const std = @import("std");
const server = @import("server");
const types = server.types;
const contract = server.contract;

fn parse(argv: []const []const u8, out: *types.Options, error_buffer: []u8) bool {
    @memset(error_buffer, 0);
    return contract.parseArgs(argv, out, error_buffer);
}

fn errorText(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

test "server defaults and exit codes match the baseline" {
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

test "help bypasses the protocol requirement but not a malformed neighbour" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/h" }, &options, &error_buffer));
    try std.testing.expect(options.help);
    try std.testing.expect(!parse(&.{ "server", "/h", "/s=" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.missing_value, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/help", "/p", "invalid" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.out_of_range, errorText(&error_buffer));
    // The help switch never masks a capacity budget the run could not satisfy.
    try std.testing.expect(!parse(&.{ "server", "/h", "/p", "tcp", "/rio-buffer", "1048576", "/cq", "64", "/memory", "1048576" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.memory_capacity, errorText(&error_buffer));
}

test "switch classification and values are ASCII exact" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/P", "TcP", "--S=7000", "-Q", "/StAtS" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u16, 7000), options.port);
    try std.testing.expect(options.quiet and options.stats);
    // A token that only looks like a switch is a value, and a non-numeric value is a number error.
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "/1" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.invalid_number, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.missing_value, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.missing_value, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/quiet=yes" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.unexpected_value, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/foo", "bar" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.unknown_switch, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "tcp" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.unexpected_target, errorText(&error_buffer));
}

test "protocol-specific switches and UDP promotion match the baseline" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/k", "2" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.protocol_option, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "udp", "/t", "2" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.protocol_option, errorText(&error_buffer));
    // The datagram path is single threaded whatever the worker switch says.
    try std.testing.expect(!parse(&.{ "server", "/p", "udp", "/threads", "2" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.protocol_option, errorText(&error_buffer));
    try std.testing.expect(parse(&.{ "server", "/p", "udp", "/threads", "1" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u32, 1), options.worker_count);
    try std.testing.expect(parse(&.{ "server", "/p", "udp" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u32, 65507), options.rio_buffer_bytes);
    try std.testing.expectEqual(@as(u32, 1), options.worker_count);
    try std.testing.expect(!parse(&.{ "server", "/p", "udp", "/rio-buffer", "65506" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.payload_size, errorText(&error_buffer));
    try std.testing.expect(parse(&.{ "server", "/p", "udp", "/rio-buffer", "65507" }, &options, &error_buffer));
    // Each datagram slot reserves one queue entry per direction.
    try std.testing.expect(!parse(&.{ "server", "/p", "udp", "/k", "129", "/cq", "256" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.cq_capacity, errorText(&error_buffer));
}

test "explicit zero values and numeric boundaries match the baseline" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    try std.testing.expect(parse(&.{ "server", "/p", "tcp", "/s", "1", "/t", "4294967295", "/w", "0", "/b", "2147483647", "/threads", "0", "/rio-buffer", "1048576", "/cq", "1048576", "/memory", "1073741824" }, &options, &error_buffer));
    try std.testing.expectEqual(@as(u32, 0), options.run_seconds);
    try std.testing.expectEqual(@as(u32, 0), options.worker_count);
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "0" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.out_of_range, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/cq", "63" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/memory", "1048575" }, &options, &error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", "18446744073709551616" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.invalid_number, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "sctp" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.out_of_range, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server" }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.missing_protocol, errorText(&error_buffer));
}

test "capacity, partial-send and notification contracts match the baseline" {
    try std.testing.expectEqual(@as(?u64, 4194304), contract.checkedProduct(u64, 1024, 4096));
    try std.testing.expect(contract.checkedProduct(u64, std.math.maxInt(u64), 2) == null);
    try std.testing.expect(contract.checkedArenaBytes(1024, 65536, 1024) == null);
    try std.testing.expectEqual(@as(?u64, 67108864), contract.checkedArenaBytes(1024, 65536, 67108864));
    try std.testing.expectEqual(@as(u32, 512), contract.tcpConnectionCapacity(1024, 800));
    try std.testing.expectEqual(@as(u32, 300), contract.tcpConnectionCapacity(1024, 300));
    // The bounded accept window: two per worker, at least eight and at most 128.
    try std.testing.expectEqual(@as(u32, 8), contract.acceptOperationCount(1));
    try std.testing.expectEqual(@as(u32, 128), contract.acceptOperationCount(64));
    // A page-rounded budget refuses an allocation the logical bytes would have fitted.
    try std.testing.expectEqual(@as(?u64, 5000), contract.checkedPageRoundedArenaBytes(5, 1000, 8192, 4096));
    try std.testing.expect(contract.checkedPageRoundedArenaBytes(5, 1000, 4096, 4096) == null);
    try std.testing.expectEqual(@as(u64, 4096), contract.workerMemoryBudget(8192, 2, 0, 4096));
    try std.testing.expectEqual(@as(u64, 8192), contract.workerMemoryBudget(12288, 2, 0, 4096));
    try std.testing.expectEqual(@as(u64, 4096), contract.workerMemoryBudget(12288, 2, 1, 4096));

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
    try std.testing.expect(contract.notificationPacketMatches(9, 11, 9, 11));
    try std.testing.expect(!contract.notificationPacketMatches(9, 10, 9, 11));
}

test "a lone surrogate is diagnosed as invalid UTF-16" {
    var options: types.Options = undefined;
    var error_buffer: [types.error_capacity]u8 = @splat(0);
    // WTF-8 encodes an unpaired surrogate half as ED A0-BF xx; a valid pair is always four bytes.
    const lone = [_]u8{ 0xED, 0xA0, 0x80 };
    try std.testing.expect(!parse(&.{ "server", &lone }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.invalid_utf16, errorText(&error_buffer));
    try std.testing.expect(!parse(&.{ "server", "/p", "tcp", "/s", &lone }, &options, &error_buffer));
    try std.testing.expectEqualStrings(contract.tokens.invalid_utf16, errorText(&error_buffer));
}
