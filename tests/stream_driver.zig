const server = @import("server");

pub fn main() u8 {
    if (!server.win32.writeStdout("stdout-only\n")) return 1;
    if (!server.win32.writeStderr("stderr-only\n")) return 1;
    return 0;
}
