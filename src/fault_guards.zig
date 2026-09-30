const win32 = @import("win32.zig");
const c = win32.c;

pub fn requireNotifySuccess(status: c_int, stage: []const u8) void {
    if (status != c.ERROR_SUCCESS) win32.failFast(stage, @bitCast(status));
}

pub fn requireDequeueCount(count: u32, maximum: u32, stage: []const u8) u32 {
    if (count == c.RIO_CORRUPT_CQ or count > maximum) win32.failFast(stage, c.ERROR_INVALID_DATA);
    return count;
}

pub fn requireTransition(valid: bool, stage: []const u8) void {
    if (!valid) win32.failFast(stage, c.ERROR_INVALID_STATE);
}

pub fn requireControlPost(ok: c.BOOL, native_error: u32, stage: []const u8) void {
    if (ok == c.FALSE) win32.failFast(stage, native_error);
}
