# Zig echo server performance refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the standalone Zig TCP/UDP server's measured throughput and tail behavior using Zig-appropriate ownership and profile-guided hot-path changes while preserving all external behavior and RIO + IOCP scheduling.

**Architecture:** Retain the existing coordinator (`engine.zig`), AcceptEx admission (`tcp_acceptor.zig`), fixed TCP workers (`tcp_worker.zig`), and independent UDP RIO path (`udp.zig`). Type their resource ownership in `engine_internal.zig`, make only pre-publication setup errors recoverable, and benchmark one profiled change at a time. The external client is a measurement peer, never a build/source dependency.

**Tech Stack:** Zig `0.17.0-dev.2375+d8aab4878`, Windows x64 MSVC ABI and Microsoft SDK, Winsock RIO, IOCP/AcceptEx, PowerShell 7 benchmark/test scripts.

**Spec:** `docs/superpowers/specs/2026-10-01-zig-performance-refactor-design.md`

## Global Constraints

- Build and test this repository alone. External Zig/C++ clients are explicit optional peer paths; do not share source, generated files, libraries, or build steps with them.
- RIO alone handles TCP/UDP payload transfers and data completions; IOCP handles CQ notifications, AcceptEx completions, handoff/control, and shutdown. A notification only prompts batched `RIODequeueCompletion`, then `RIONotify` rearm. No fallback or second payload-completion mechanism.
- Keep multiple AcceptEx operations pre-posted, one owner thread per RQ/CQ, stable `OVERLAPPED`/RIO request/UDP address buffers, and exactly-once accept-socket handoff.
- Admission closes first; transit handoffs acknowledge, workers drain terminal RIO work, CQ retires on owner thread, threads join, then registered storage is freed. Socket cancellation/close is not a terminal completion.
- Preserve CLI/defaults/exit-code categories, `/w` optional duration and no-`/w` console-stop behavior, TCP idle/capacity rules, UDP datagram limits, and final/per-worker stat field names and units. Default output stays unchanged.
- Zig `error` unions/`errdefer` apply only to synchronous setup before a thread or request is published. Keep `sdk.zig` project-private extern ABI layouts and SDK probe; avoid `std.Io`, generic frameworks, or mechanical C++ class translation.
- Existing server counters are already worker-local; do not copy the client's metrics experiment without server-side profiler evidence. CPU affinity/NUMA placement is a separate future experiment, not part of the baseline refactor.
- This document does not install or verify pinned 2375. At execution, if the exact Zig binary is unavailable, pause for user direction; do not silently install it. Every source-changing commit runs `./build.ps1 -Optimize Debug` and `./build.ps1 -Optimize ReleaseFast`. No merge/push until review.

## Review Focus

1. Stop arriving while AcceptEx completion is in transit to a worker: socket transfers/acknowledges once and acceptor waits before release; Tasks 3-4 test this race.
2. A queued CQ notification during shutdown: worker drains real RIO completions and retires CQ only at zero outstanding; Tasks 2 and 5 test it.
3. TCP partial send, EOF, or idle timeout with a live request: no early connection-slot reuse and exact echo bytes; Tasks 2 and 5 test it.
4. UDP maximum 65507-byte datagram or WSAECONNRESET during receive: stable remote address/slot and correct repost or drain; Task 6 tests it.
5. Benchmark loss, corruption, network error, premature server death, or incomplete terminal drain: run is invalid and cannot support a speedup claim; Task 1 tests runner rejection.

---

## File map and dependency order

| File | Responsibility |
| --- | --- |
| `tests/perf_commands.ps1`, `tests/perf_loopback.ps1`, `tests/perf_runner_contract.ps1`, `tests/perf_workloads.json` | Explicit peer benchmark commands, provenance, raw samples, invalid-run rejection. |
| `src/engine_internal.zig` | Stable worker, connection, accept-operation, UDP-slot states and typed resource owners. |
| `src/tcp_worker.zig` | One-worker RIO CQ/IOCP loop, connection-slot lifecycle and teardown barrier. |
| `src/tcp_acceptor.zig` | AcceptEx prepost, socket transfer and in-transit acknowledgement. |
| `src/udp.zig` | Independently owned UDP RIO slots and drain. |
| `src/engine.zig`, `src/root.zig` | TCP/UDP coordination, preserved exit/output contracts. |
| `tests/engine.zig`, `tests/tcp_acceptor_driver.zig`, `tests/process_tests.ps1`, `tests/fault_process_tests.ps1`, `tests/tcp_storm.ps1` | Ownership, state, process, fault, high-concurrency, shutdown contracts. |
| `docs/perf-results-2026-10-01.md` | Baseline/profile/candidate decision log and evidence. |

Do not alter `sdk.zig`, `rio.zig`, CLI parser, or unrelated files without a focused failing test. Read the spec and plan, then execute sequentially on an isolated implementation branch/worktree from this design branch.

### Task 1: Independent benchmark runner and immutable baseline

**Files:** Create `tests/perf_commands.ps1`, `tests/perf_loopback.ps1`, `tests/perf_runner_contract.ps1`, `tests/perf_workloads.json`, `docs/perf-results-2026-10-01.md`.

**Interfaces:** `New-ClientArguments -Case <PSCustomObject> -Port <int>` returns `[string[]]` for an external finite-count client; `Test-BenchmarkRun -Run <PSCustomObject> -StopRecord <PSCustomObject>` returns `[bool]` for final acceptance after shutdown. `./tests/perf_loopback.ps1 -ServerPath <path> -ServerPid <int> -ServerArguments <string[]> -ClientPath <path> -Port <int> -Case <name> -OutputDirectory <path> -Label <string> [-DescribeOnly]` verifies the already-running server executable/PID and never starts/builds/kills either project. A manifest row has `name`, `protocol`, `payload_bytes`, `pipeline_depth`, `sessions`, `threads`, `cq`, `memory_bytes`, `socket_buffer_bytes`, `rio_buffer_bytes`, `udp_depth`, `echo_count`.

- [ ] Write `tests/perf_runner_contract.ps1`: TCP `/k 8` with `/n 17` and UDP 65507 argument vectors contain `/n`, never client `/w`; declared server arguments include `/stats` but no `/w`; reject wrong process image/hash, zero/negative count, short run under 10 s, `corrupted`/`lost`/`network_errors` nonzero, nonzero client exit, or absent server terminal `active=0`/`outstanding=0` in a separate stop record. `-DescribeOnly` skips live-process checks and does not run a binary.
- [ ] Run `pwsh -NoProfile -File tests/perf_runner_contract.ps1`; expect failure because command builder/runner are absent.
- [ ] Implement four minimum cases: TCP 128 `/k 1`, TCP 4096 `/k 8`, UDP 1200 and 65507; add TCP 256/1024/4096-session sweep where the configured capacity allows. Start pilot `/n 100000`, double until a valid measured run lasts at least 10 s, freeze exact counts in manifest. Runner stores declared server arguments plus observed process path/PID, stdout/stderr, exit, SHA-256 and commits of both executables, Zig/Windows/CPU, wall/process CPU time, and provisional per-run validity under unique ignored `zig-out/bench/<label>/` paths. `-DescribeOnly` must not run processes; final validity requires `Test-BenchmarkRun` with a terminal stop record.
- [ ] Run the contract and full Debug/ReleaseFast self-contained suites with pinned Zig 2375; expect PASS. With separately supplied client and already-running server, warm up and collect seven valid samples per case, one pair at a time; stop the server through its existing console control path and separately verify final zero outstanding. Record a separately built C++ server as an informative reference, not the Zig acceptance baseline. Preserve baseline binary/hash and profiler evidence for handoff/CQ/connection/UDP paths. Review decisions use `delta > max(0.05 * baseline_median, 3 * baseline_MAD)` in that metric's units.
- [ ] Commit runner/manifest/report (`git add tests/perf_commands.ps1 tests/perf_loopback.ps1 tests/perf_runner_contract.ps1 tests/perf_workloads.json docs/perf-results-2026-10-01.md`; `git commit -m "test: establish Zig server performance baseline"`). Raw samples remain local during runs; attach a hashed raw-sample archive to implementation review so results are inspectable.

### Task 2: Type stable owners without altering the event model

**Files:** Modify `src/engine_internal.zig`, `src/tcp_worker.zig`, `src/tcp_acceptor.zig`, `src/engine.zig`, `tests/engine.zig`.

**Interfaces:** Add `internal.WorkerResources` and `internal.AcceptorResources` with the current owned fields; change `Worker.resources: ?*WorkerResources` and `Acceptor.resources: ?*AcceptorResources` from `?*anyopaque`. Keep `tcp_worker.WorkerResources` and `tcp_acceptor.AcceptorResources` as aliases for existing callers. No native `extern` structure changes.

- [ ] Add compile-time assertions that `Worker.resources` and `Acceptor.resources` have the typed pointers; test partly initialized, unpublished owners release only acquired resources, published worker cannot release with active connection/request or armed notification, queued notification identity is checked before drain/rearm, and partial send/EOF preserve slot until outstanding reaches zero.
- [ ] Run `./build.ps1 -Optimize Debug`; expect the new typed-owner test/import to fail before implementation.
- [ ] Move owner types into `engine_internal.zig`, remove resource-pointer casts, keep all preallocated arrays and context addresses stable, and preserve `destroyWorker`/`destroyAcceptor` terminal barriers. Do not change CQ `batch_size=256`, AcceptEx count, or distribution.
- [ ] Run full Debug and ReleaseFast suites including fault, TCP storm, and stop/drain process tests; expect PASS and identical stat fields.
- [ ] Commit (`git add src/engine_internal.zig src/tcp_worker.zig src/tcp_acceptor.zig src/engine.zig tests/engine.zig`; `git commit -m "refactor: type server worker and acceptor ownership"`).

### Task 3: Recoverable synchronous setup with explicit publication boundary

**Files:** Modify `src/tcp_worker.zig`, `src/tcp_acceptor.zig`, `src/engine.zig`, `tests/engine.zig`, `tests/tcp_acceptor_driver.zig`, `tests/fault_driver.zig`.

**Interfaces:** `tcp_worker.initializeWorker(worker: *internal.Worker, api: *const rio.Api, options: *const types.Options, failed: *std.atomic.Value(bool), worker_index: u32, worker_count: u32, resource_storage: *internal.WorkerResources) WorkerInitError!void`; `tcp_acceptor.initializeAcceptor(acceptor: *internal.Acceptor, api: *const rio.Api, options: *const types.Options, workers: []internal.Worker, failed: *std.atomic.Value(bool), resource_storage: *internal.AcceptorResources) AcceptorInitError!void`. `WorkerInitError = error{Port, ReadyEvent, Capacity, Arena, Connections, FreeIndices, TimerNodes, TimerPositions, SocketOwners, TimerHeap, Registration, CompletionQueue}`; `AcceptorInitError = error{WorkerCount, Listener, Port, ReadyEvent, ConfigureSocket, BindListen, AssociateIocp, AcceptExExtension, AddressExtension, Operations}`. `engine.runServer` maps these failures to `.network` and keeps native stage/error diagnostics.

- [ ] Extend fault drivers to fail each pre-publication stage and assert no socket/handle/registration leak; add a test that a thread-start/readiness failure is not treated as pre-publication cleanup and is joined before release.
- [ ] Run `./build.ps1 -Optimize Debug`; expect the new error-union tests to fail while initialization returns `bool`.
- [ ] Convert setup functions to typed errors and pre-publication `errdefer`; on setup failure reset owner and `resources` pointer, and change coordinator cleanup so it never destroys an already rolled-back failed initializer. After thread or AcceptEx publication, use the existing stop/ack/drain path, never lexical cleanup. Preserve all invariant fail-fast behavior and output/exit codes.
- [ ] Run both full suites, process/fault tests, and 4-way Zig/C++ TCP+UDP interoperability via explicit external executable paths; include an AcceptEx completion racing with stop and verify exactly one transit acknowledgement.
- [ ] Commit (`git add src/tcp_worker.zig src/tcp_acceptor.zig src/engine.zig tests/engine.zig tests/tcp_acceptor_driver.zig tests/fault_driver.zig`; `git commit -m "refactor: stage server setup errors before publication"`).

### Task 4: Profile-gated AcceptEx handoff experiment

**Files:** Modify `src/tcp_acceptor.zig`, `src/tcp_worker.zig`, `tests/engine.zig`, `tests/tcp_acceptor_driver.zig`, `docs/perf-results-2026-10-01.md` only if the baseline profile identifies acceptor/handoff pressure.

**Interfaces:** Keep `postAccept(*internal.AcceptOperation) bool`, `postHandoff(*internal.Worker, *internal.AcceptOperation) void`, and `transitionState(*internal.AcceptOperation, internal.AcceptState, internal.AcceptState) bool`. Try exactly one change to the worker-selection/handoff policy; keep multiple AcceptEx requests pre-posted and the current 32-per-worker, max-1024 pool in this task. Record the proposed policy and expected bottleneck before editing.

- [ ] If the profile shows no handoff contention/imbalance, write `SKIPPED: no handoff evidence` in the report and make no source change. Otherwise add a failing test for the chosen policy and a stop/in-transit race with exactly one socket owner and acknowledgement.
- [ ] Run focused Debug engine/acceptor tests; expect failure for the selected policy before implementation.
- [ ] Implement only that worker-selection/handoff policy, without changing the accept pool, RIO queues, or thread affinity.
- [ ] Run full Debug/ReleaseFast suites, TCP storm/capacity reuse/stop-drain, four Zig/C++ interop combinations, and seven valid A/B/A samples per frozen case. Retain only a correctness-clean median gain greater than both 5% and 3 baseline MAD with no meaningful throughput or p99/p999 regression elsewhere; otherwise revert only this experiment and document it.
- [ ] Commit accepted source+report or report-only skip/rejection (`git commit -m "perf: evaluate server accept handoff"`).

### Task 5: Profile-gated CQ or connection-layout experiment

**Files:** Modify `src/tcp_worker.zig`, optionally `src/engine_internal.zig`, `tests/engine.zig`, `tests/process_tests.ps1`, `docs/perf-results-2026-10-01.md` only when profiling identifies this path.

**Interfaces:** Choose exactly one: CQ dequeue `batch_size` 128 versus current 256 versus 512, or a stable hot/cold `Connection` layout with identical request-context identity. `internal.requestContextValid(*const Request, []const Connection) bool` remains the identity check; `tcp_worker.applySuccessfulProgress(*Connection, EngineOperation, u32) Progress` retains partial-send semantics.

- [ ] If no CQ/connection hotspot is evidenced, record a skip. Otherwise add a failing test for the selected batch constant/layout itself plus its invariant: complete CQ drain before rearm with queued notification, or stable request/connection address and no early slot reuse on partial send/EOF/idle timeout.
- [ ] Run the focused Debug test and confirm it fails before the selected change.
- [ ] Implement only the chosen batch/layout change, preserving owner-thread affinity of queue operations and stable published addresses. Do not change admission policy or UDP in this task.
- [ ] Run both full suites, TCP storm/capacity reuse/fault/stop tests, four-way interop, and seven valid A/B/A runs. Reject any corruption, unaccounted error, nonzero terminal active, tail regression, or median gain below both thresholds.
- [ ] Commit accepted source+report or report-only skip/rejection (`git commit -m "perf: evaluate server TCP completion path"`).

### Task 6: Profile-gated UDP slot experiment and final acceptance

**Files:** Modify `src/udp.zig`, optionally `src/engine_internal.zig`, `tests/engine.zig`, `tests/process_tests.ps1`, `tests/udp_stop_driver.zig`, `docs/perf-results-2026-10-01.md` only if UDP profile evidence selects a slot-layout or repost-path change.

**Interfaces:** Keep `udp.run(*const rio.Api, *const types.Options, *std.atomic.Value(bool)) types.ExitCode`, `internal.udpContextValid(*const UdpSlot, []const UdpSlot) bool`, and registered payload/remote-address buffers stable through terminal completion. No UDP payload I/O outside `RIOReceiveEx`/`RIOSendEx`.

- [ ] If no UDP slot/repost hotspot is evidenced, record a skip. Otherwise add a failing test for the selected layout/repost policy itself plus 1200/65507-byte echo, WSAECONNRESET recoverable receive, stop with outstanding send/receive, and `outstanding=0` after drain.
- [ ] Run focused Debug/process UDP tests; expect failure for the selected change before implementation.
- [ ] Implement one measured UDP change; keep slot/context addresses and remote address registration stable, and never free them on socket close alone.
- [ ] Run both full suites, four Zig/C++ TCP+UDP combinations (normal TCP batching and partial tail), repeated startup/shutdown, and seven valid A/B/A runs per frozen workload. Latency claims require the same precise external client probe on baseline and candidate; coarse power-of-two bins alone do not establish a p99/p999 win.
- [ ] Commit accepted source+report or report-only skip/rejection. Final report states exact commits/binary hashes/peer, machine/toolchain, raw samples, median/MAD and p99/p999, zero terminal active/outstanding, and labels every candidate accepted, inconclusive, rejected, or skipped.

## Completion boundary

Only current pinned-2375 builds, full self-contained suites, explicit external interoperability, shutdown convergence, and reproducible noise-aware benchmark evidence justify completion or a performance claim. Do not merge/push merely because the code builds. This document is a plan, not evidence that any optimization is implemented.
