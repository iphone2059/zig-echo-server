const server = @import("server");

pub fn main() u8 {
    if (!server.native.diagnostics.writeStdout("stdout-only\n")) return 1;
    if (!server.native.diagnostics.writeStderr("stderr-only\n")) return 1;
    return 0;
}
