# Zig echo server performance refactor: evidence log

Status: implementation in progress. This document distinguishes correctness evidence, a baseline, and any later candidate result. No throughput or tail-latency improvement has yet been established.

## Frozen baseline

- Machine: 12th Gen Intel Core i7-12700H; Windows NT 10.0.26300.0; loopback IPv4.
- Toolchain: Zig `0.17.0-dev.2375+d8aab4878`, Windows x64 MSVC ABI.
- Server source: `f8be8e0ced1f76086242cdca032469db17c6ee01`; immutable ReleaseFast executable SHA-256 `103bc0c5df9ddd5981ed40cfa91d8a6ba5e53c0bd158aaf5c7c75428f22f5439`.
- External instrumented Zig client source: `557cc03dab581347147b1b682076d4992c3137d0`; executable SHA-256 `a2e905f2a215fdae9ebd1e4059f83fe6322ed46af3f650ed2db2216a217db72a`.
- Both executables are separate projects. The client is only a benchmark peer. The server runs without `/w`; a dedicated isolated-console helper sends Ctrl+Break, checks process exit 0, and verifies terminal TCP `active=0` plus all worker `active=0`, or UDP `outstanding=0`.
- Each workload is warmed up and has seven measured samples of at least 10 seconds. The manifest in `tests/perf_workloads.json` freezes counts, sessions, CQ, registered memory, and payload size. A measured run is valid only with exact echoed count/bytes, zero corruption/loss/network errors, zero stderr, a live server during the run, matching executable identity/hash, and a separate clean-stop record.

| Workload | Count per sample | Median echoes/s | MAD echoes/s | Median p99 µs ~ | Median p999 µs ~ |
| --- | ---: | ---: | ---: | ---: | ---: |
| TCP 128 B, 256 sessions, `/k 1` | 6,400,000 | 244,704 | 4,707 | 1,472 | 3,168 |
| TCP 4096 B, 256 sessions, `/k 8` | 25,600,000 | 1,066,845 | 126,573 | 3,872 | 7,360 |
| UDP 1200 B, 256 sessions | 3,200,000 | 137,004 | 3,322 | 2,112 | 2,720 |
| UDP 65507 B, 256 sessions | 1,600,000 | 62,131 | 821 | 4,864 | 7,168 |
| TCP 128 B, 1024 sessions, `/k 1` | 3,200,000 | 226,340 | 2,595 | 6,016 | 9,472 |
| TCP 128 B, 4096 sessions, `/k 1` | 3,200,000 | 150,780 | 2,985 | 36,864 | 77,824 |

The p99/p999 values are medians of the client's **batch** latency approximations, not precise per-echo tail-latency measurements. They cannot support a tail-latency win claim. Large-report noise in TCP 4096 B (`MAD=126,573` echoes/s) especially requires cautious comparison. A later candidate must beat `max(5% of baseline median, 3 × baseline MAD)` in the selected metric without a meaningful regression elsewhere.

The 4096-session workload first ran seven times against one continuously running server. Runs 1–6 had zero errors; run 7 completed all 3,200,000 echoes but logged 923 `ConnectEx` `native_error=1225` failures. That series is **invalid** and retained in the raw archive. Seven separate server lifetimes, each with a warmup, measured run, and normal terminal drain, subsequently passed. This establishes a valid per-run baseline but does **not** explain the long-lived server failure; any candidate acceptance must include a repeated-run longevity check.

Raw baseline archive (including the invalid series): `zig-out/bench/baseline/raw-samples-2026-10-01.zip`; SHA-256 `145af75f9a4eb4b0ff992fa5ffeb18c8d09489be9b47b8128b3c28402fce17dc`. This ignored local artifact is not committed. The per-run JSON, stdout/stderr, server stdout/stderr, stop records, and source hashes are inside it.

### Provenance correction

The initial baseline runner inferred `client_commit` from the current client worktree when its immutable executable lacked a `source-commit.txt` marker. Consequently the archived per-run JSON says `d325c5a7c5f5780833cb3295e510e16d568372c7` in that field, which is the worktree HEAD at measurement time, **not** the build source. The actual instrumented binary came from `557cc03dab581347147b1b682076d4992c3137d0`; its SHA-256 above is unaffected. The original archive is preserved without rewriting. The runner now requires a 40-digit source marker before launching a live measurement, and both immutable binary directories have one.

## Profiling and C++ reference

The first `wpr -start CPU -filemode` attempt failed with `0xc5585011` (`Failed to enable the policy to profile system performance`). A later verbose/file-mode run wrote 9.5 GB but reported 69,894 dropped events, so it was rejected and that invalid, uncommitted ETL was deleted. Subsequent `CPU.light` memory-mode traces were valid: `xperf -a tracestats` reported **zero lost buffers and zero lost events** for both TCP and UDP. The candidate PDB was copied beside the immutable executable for function-symbol resolution.

| Candidate trace | Workload | ETL bytes | SHA-256 | Selected `xperf -a profile -detail` sample weights |
| --- | --- | ---: | --- | --- |
| `zig-out/bench/profiles/server-tcp-light-2026-10-01.etl` | TCP 128 B `/k 1` | 201,326,592 | `4e48bfd63196e6b35fc290ccb873203da4d2c3687f488a39d6b5483b16485c62` | `workerThread` 1,057,253; `acceptorThread` 1,035; `ntoskrnl.exe` 115,177,236; `NETIO.SYS` 54,985,051; `tcpip.sys` 38,435,662 |
| `zig-out/bench/profiles/server-udp-light-2026-10-01.etl` | UDP 65507 B | 260,046,848 | `99f23cfc80cd89b9ad285dc3ca116de7c0601387604a969802b47cb4708581a8` | inlined server `runServer` 96,070; `ntoskrnl.exe` 11,152,779; `NETIO.SYS` 11,818,889; `tcpip.sys` 5,211,271 |

These are sampled profile weights, not exact per-function CPU time or proof that kernel internals can be optimized here. The valid traces were taken on the structurally refactored candidate because baseline WPR capture initially failed; the data-path/event policy did not change between those binaries. They provide no evidence that changing AcceptEx selection, CQ batch/connection layout, or UDP slot/repost logic is the next useful intervention.

**Task 4 — SKIPPED: no handoff evidence.** The resolved TCP trace has negligible `acceptorThread` weight relative to networking work. No worker-selection or handoff policy source change was made; the current 32-per-worker/max-1024 AcceptEx pool and exactly-once transit acknowledgement remain intact. The limitation is that this profile alone does not prove every possible admission imbalance absent on other hardware or workloads.

**Task 5 — SKIPPED: no CQ/connection-layout hotspot evidence.** `workerThread` appears in the valid TCP trace, but the function bucket includes the whole worker loop; this sample does not isolate `RIODequeueCompletion`, timer handling, or any `Connection` field access as a dominant cost. Testing 128/512 against the unchanged CQ `batch_size=256`, or reorganizing stable request contexts, would be an ungrounded change. Both existing RIO CQ rearm ordering and partial-send/EOF tests remain green; no Task 5 source change was made.

An existing independently built C++ server executable is available at `cpp-echo-server/build/release/cpp-echo-server.exe`, SHA-256 `393a0616c55faabdba6812f3b82bff6a8eda9bc13cfb6235fe505dae92f04d38`. Its exact build-source provenance was not established by the no-op incremental build, so it is not part of the Zig acceptance baseline or the table above. Cross-project interoperability will be tested separately.

## Candidate decisions

Typed-owner and synchronous-initialization refactors are committed and passed Debug/ReleaseFast suites. Candidate benchmark and A/B/A decisions are being finalized below; no hot-path optimization is accepted or claimed yet.
