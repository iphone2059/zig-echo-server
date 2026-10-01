# Zig echo server: performance-first refactor design

Date: 2026-10-01

Status: written design for user review; not an implementation plan

## Intent and boundary

Improve TCP/UDP throughput and tail latency on reproducible Windows loopback workloads while retaining the server's native RIO/IOCP architecture and observable behavior. Larger internal changes are allowed only when measured and independently verified. This server remains a self-contained repository; a separately built client is an optional benchmark/interoperability peer, not a source, link, or build dependency.

The starting implementation is commit `041bd0e`. TCP already separates coordinator (`src/engine.zig`), AcceptEx admission (`src/tcp_acceptor.zig`), and fixed workers (`src/tcp_worker.zig`). UDP owns its RIO path in `src/udp.zig`. `src/engine_internal.zig` holds stable connection/accept contexts and lifecycle state. These boundaries are retained unless profiling identifies a specific cost. The refactor is not a license to merge the independent projects or copy the C++ file organization mechanically.

## Preserved contract

- Keep the current CLI flags, defaults, validation, exit-code categories, TCP and UDP echo behavior, `/w` optional run duration, TCP idle timeout, capacity rules, and existing final/per-worker statistic field names and units. Without `/w`, the server runs until a console stop event.
- Payload I/O remains RIO only. IOCP handles RIO CQ notification, AcceptEx completions, admission handoff/control, and shutdown coordination. Multiple AcceptEx operations remain pre-posted; no ordinary Winsock payload I/O, polling fallback, or second payload-completion mechanism is introduced.
- Each worker owns its RQ/CQ access, registered arena, connection slots, timers, and notification state. Acceptor-to-worker handoff transfers socket ownership exactly once. UDP slots and remote-address buffers remain stable and registered while in flight.
- Shutdown closes admission, drains handoffs and all terminal RIO completions, verifies zero outstanding operations, retires each CQ on its owner thread, joins threads, then deregisters/frees memory and reports TCP `active=0` or UDP `outstanding=0`. Socket closure/cancellation does not permit early context reuse or buffer release.
- Keep project-private Microsoft SDK ABI declarations and the ABI probe. The server must build and pass its self-contained suite without any sibling project's source, build output, or test binary.

## Measurement contract

Before a hot-path change, save a ReleaseFast baseline from the first verified post-upgrade commit using pinned Zig `0.17.0-dev.2375+d8aab4878`. Add a project-local loopback benchmark recipe/runner that records the exact server and externally supplied client executable, commits/hashes, Zig/Windows/CPU details, command lines, process CPU time, raw output, and exit status beneath ignored `zig-out/bench/`. It neither builds nor imports the client. Use a finite client `/n` rather than a client `/w`; keep the server alive through each measured run and stop it separately through the existing console control path. Shutdown correctness remains a distinct acceptance test, not an inference from a forced benchmark-process termination.

After a pilot freezes counts that run for at least 10 seconds on this machine, measure TCP 128-byte `/k 1`, TCP 4096-byte `/k 8`, UDP 1200-byte, and UDP 65507-byte cases. Sweep TCP connection counts 256, 1024, and 4096 where configured capacity permits. Record `/threads`, `/cq`, `/memory`, `/rio-buffer`, UDP `/k`, socket buffers, and the exact client peer. Run only one pair at a time; warm up and collect at least seven measured runs per workload, interleaving baseline/candidate/baseline when possible. A loss, corruption, network error, capacity failure, or incomplete final server drain makes a run invalid for performance comparison. Record the separately built C++ server with the same client/workload as an informative reference, not as the acceptance baseline for a Zig-only source change.

Use the client's batch-latency histogram only as a coarse screen: its power-of-two buckets cannot substantiate small tail-latency gains. A finer benchmark-only, bounded worker-local histogram in the client peer (or an equivalently precise external probe) is required before claiming p99/p999 improvement; baseline and candidate runs use the same peer/instrumentation mode. Keep production server output unchanged. Compare median throughput and p99/p999 across runs together with median absolute deviation. A claimed gain must exceed both 5% and three baseline median absolute deviations, without another required workload regressing beyond the same noise-aware threshold. Inconclusive variance means more controlled measurements, not a performance claim.

## Refactor and optimization sequence

1. Capture the immutable baseline and run full Debug/ReleaseFast self-contained tests. Keep old and candidate binaries available for same-machine A/B/A comparison.
2. Refine Zig ownership boundaries only where they clarify setup or shutdown. Use explicit `init`/`deinit` and typed recoverable errors for synchronous setup; `errdefer` is valid before asynchronous publication, never as a substitute for the AcceptEx/RIO completion barrier. Preserve SDK `extern` layouts and stable addresses for `OVERLAPPED`, RIO requests, and slots.
3. Profile the TCP acceptor-to-worker handoff, worker CQ drain/notification, per-connection state access, and UDP slot path. Try one measured candidate at a time: admission distribution or prepost depth, CQ batch size, connection hot/cold layout, or UDP slot layout. Existing server counters are already worker-local, so do not mirror a client metrics refactor without evidence.
4. Keep fixed worker/RQ/CQ ownership and the same notification arm/dequeue ordering throughout. CPU affinity or NUMA placement is a separate optional experiment after single-variable wins; it is not silently folded into the baseline refactor because it changes scheduling conditions and can improve throughput while worsening tails.

## Verification and completion gates

- Every intermediate commit passes the server's self-contained contracts, SDK ABI probe, source policy, process/fault tests, TCP connection storm, capacity reuse, split I/O, idle timeout, UDP 65507-byte datagram, and stop/drain tests. Add a focused regression test before altering an ownership or state transition.
- Run Zig/C++ interoperability in all four client/server combinations for TCP and UDP after each material change. Explicit external paths keep the repository independently buildable.
- Verify repeated startup/shutdown, overlapping accept completions and stop, full CQ drains, notification re-arm identity, and zero terminal outstanding work. No early release, double ownership transfer, or silent fallback is acceptable.
- Publish raw samples and comparison method. Reject a throughput improvement that materially worsens p99/p999 or shutdown convergence. A behavior-preserving structural cleanup with performance inside measured noise may remain, but is not described as a speedup.
- Implementation lives on an isolated branch/worktree and is not merged or pushed solely because it compiles. The written design and later implementation plan need review before coding.

## Exclusions

No cross-project common source, a different payload I/O model, ordinary socket fallback, deletion of AcceptEx preposting, shared multi-worker RIO queue access, CLI redesign, or unmeasured large-scale NUMA/affinity restructuring.
