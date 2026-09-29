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
