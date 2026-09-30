# zig-echo-server

Independent Windows TCP/UDP echo server rewritten from `cpp-echo-server` in Zig. The data path is always Winsock Registered I/O (RIO); IOCP is used for RIO CQ notification, TCP `AcceptEx` admission, worker control, and shutdown coordination. There is no ordinary `send`/`recv`, `WSAPoll`, `select`, or `std.net` fallback.

## Toolchain

- Windows x64, MSVC ABI
- Zig `0.17.0-dev.2320+1e770dbef`
- Visual Studio C++ tools and Windows SDK
- PowerShell 7 for the full integration suite

The project owns its Win32/RIO ABI declarations and all implementation code. It has no source or build dependency on any client or sibling echo project. The default acceptance suite uses local .NET loopback peers; the separately built C++ client is an optional external interoperability peer.

## Build

From the project root:

```powershell
.\build.ps1 ReleaseFast
```

`build.ps1` pins `C:\bin\zig-x86_64-windows-0.17.0-dev.2320+1e770dbef\zig.exe`, discovers Visual Studio through `vswhere`, initializes the x64 MSVC/SDK environment, builds the executable, and runs the complete suite. Use `-BuildOnly` to omit tests.

Artifacts are written to `zig-out\bin`.

## TCP

```powershell
.\zig-out\bin\zig-echo-server.exe `
  /p tcp /s 7000 /threads 8 /t 300 /rio-buffer 16384 `
  /cq 65536 /memory 2147483648 /q /stats
```

TCP uses multiple pre-posted `AcceptEx` operations. Each accepted socket is handed to one fixed worker, which owns its RIO RQ, registered-buffer slot, timer entry, and RIO CQ. IOCP wakes the worker once the CQ is readable; the worker drains completions in batches and re-arms `RIONotify`.

## UDP

```powershell
.\zig-out\bin\zig-echo-server.exe `
  /p udp /s 7000 /k 4096 /rio-buffer 65507 `
  /cq 8192 /memory 1073741824 /q /stats
```

UDP uses fixed registered payload/address slots, `RIOReceiveEx`/`RIOSendEx`, batched CQ drain, and an outstanding-operation shutdown barrier.

`/w seconds` requests a finite server run. Omitting `/w` leaves the server running until Ctrl+C, Ctrl+Break, or console close. `/t seconds` is the TCP idle timeout. `/stats` prints per-worker TCP lines followed by the aggregate terminal line; UDP prints its aggregate terminal line. Successful statistics go to stdout, while errors go to stderr.

## Tests

Run the complete Debug and optimized gates:

```powershell
.\build.ps1 Debug
.\build.ps1 ReleaseFast
```

The self-contained suite covers CLI contracts, timer/reference models, native resource ownership, real RIO-CQ-to-IOCP worker lifecycle, AcceptEx ownership transitions, split TCP I/O, capacity exhaustion and reuse, idle timeout, a connection storm overlapping shutdown, TCP/UDP loopback echo including 65507-byte datagrams, deterministic exit-4 production-guard boundaries, and source-policy rejection of fallback APIs or cross-project imports.

Individual integration gates can also be run after a build:

```powershell
pwsh -NoProfile -File .\tests\process_tests.ps1
pwsh -NoProfile -File .\tests\fault_process_tests.ps1
pwsh -NoProfile -File .\tests\source_policy.ps1
```

Optional C++ client interoperability (after separately building that executable):

```powershell
pwsh -NoProfile -File .\tests\process_tests.ps1 `
  -CppClientPath ..\cpp-echo-client\build\release\cpp-echo-client.exe
```
