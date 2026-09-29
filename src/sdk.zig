pub const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cInclude("winsock2.h");
    @cInclude("windows.h");
    @cInclude("mswsock.h");
    @cInclude("ws2tcpip.h");
});
