# zig-echo-server — Zig 0.17-dev + Microsoft Windows SDK

This is the first executable migration slice of the supplied `cpp-echo-server`.

Implemented here:

- Microsoft Windows SDK headers via `@cImport` (`winsock2.h`, `windows.h`, `mswsock.h`, `ws2tcpip.h`).
- MSVC ABI target.
- RIO function table loaded with `WSAIoctl(SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER, WSAID_MULTIPLE_RIO)`.
- `VirtualAlloc` + `RIORegisterBuffer`.
- RIO CQ notified through IOCP.
- Production-style UDP RIO echo loop with fixed slots, no hot-path allocation, notification state tracking, CQ corruption fail-fast, shutdown drain, and final statistics.
- Contract and indexed timer-heap modules/tests, ready for the TCP slice.

## Prerequisites

Use Zig `0.17.0-dev.2320+1e770dbef` and VS 2022 + Windows SDK. Start **Developer PowerShell for VS 2022** (x64), then:

```powershell
zig version
.\build.ps1 ReleaseFast
```

Direct command:

```powershell
zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast
```

The build deliberately reads the `INCLUDE` and `LIB` environment variables from the VS developer environment. This forces SDK/MSVC headers and libraries to participate rather than silently using Zig's bundled MinGW include tree.

## Run

```powershell
.\zig-out\bin\zig-echo-server.exe /p udp /s 7000 /k 4096 /cq 8192 /memory 1073741824 /stats
```

## Tests

```powershell
zig build test -Dtarget=x86_64-windows-msvc -Doptimize=Debug
```

The next TCP slice should port the original per-worker CQ/IOCP model plus `AcceptEx` handoff without introducing `std.net` or ordinary `recv/send` fallbacks.


> Validation note: this package was source-reviewed in a non-Windows environment; run the first build in VS 2022 Developer PowerShell so Microsoft SDK `@cImport` translation is validated by Zig on the target machine.
