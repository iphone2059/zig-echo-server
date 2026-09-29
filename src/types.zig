pub const Protocol = enum(u8) {
    none = 0,
    tcp = 1,
    udp = 2,
};

pub const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    network = 2,
    echo_failure = 3,
    internal = 4,
};

pub const Options = struct {
    protocol: Protocol = .none,
    port: u16 = 7,
    timeout_seconds: u32 = 300,
    run_seconds: u32 = 0,
    socket_buffer_bytes: u32 = 0,
    udp_depth: u32 = 256,
    worker_count: u32 = 0,
    rio_buffer_bytes: u32 = 16 * 1024,
    cq_capacity: u32 = 4096,
    memory_bytes: u64 = 1024 * 1024 * 1024,
    quiet: bool = false,
    stats: bool = false,
    help: bool = false,
};

pub const max_udp_payload: u32 = 65507;
