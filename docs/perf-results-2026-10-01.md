# Zig echo server performance refactor: evidence log

Status: the typed-ownership and pre-publication setup refactor is implemented and verified on the isolated implementation branch. The three profile-gated hot-path experiments were skipped for lack of path-specific evidence. No throughput or tail-latency improvement is claimed.

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

**Task 6 — SKIPPED: no UDP slot/repost hotspot evidence.** The valid 65507-byte UDP trace resolves very little CPU weight to server application code relative to Windows networking modules and does not isolate `UdpSlot` layout or receive repost as a bottleneck. No UDP source change was made. The existing maximum-datagram, recoverable receive-error and terminal `outstanding=0` tests remain in the full suite.

An existing independently built C++ server executable is available at `cpp-echo-server/build/release/cpp-echo-server.exe`, SHA-256 `393a0616c55faabdba6812f3b82bff6a8eda9bc13cfb6235fe505dae92f04d38`. Its exact build-source provenance was not established by the no-op incremental build, so it is not part of the Zig acceptance baseline or the table above. As an independent functional reference, this executable passed the same eight external Zig/C++ client cases listed below, including normal Ctrl+Break stop and terminal zero active/outstanding. A same-frozen-workload quantitative C++ reference has **not** been measured; do not infer relative Zig/C++ performance from these interoperability cases.

## Candidate decisions

The structural candidate source is `562d70f81619c83ffd713d17f2f49a40caef7b32`, immutable ReleaseFast server SHA-256 `dba4d34883f0fb9eded6c6a948a383c717b692dfc2863a4b51fff039cf4ecf07`. The peer is the **same** instrumented Zig client binary and SHA-256 used for the baseline. Each row below has seven valid baseline and seven valid candidate runs, exact echoed bytes, zero corruption/loss/network errors, and an independently verified server exit 0 with terminal TCP `active=0` or UDP `outstanding=0`. The original baseline 4096-session series with the failing seventh run is excluded; both compared 4096-session sets use seven separate server lifetimes.

| Workload | Baseline median echoes/s ± MAD | Candidate median echoes/s ± MAD | Delta | Median batch p99 µs ~ (A→B) | Median batch p999 µs ~ (A→B) | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| TCP 128 B `/k 1` | 244,704 ± 4,707 | 252,984 ± 16,717 | +3.38% | 1,472→1,392 | 3,168→2,784 | Inconclusive |
| TCP 4096 B `/k 8` | 1,066,845 ± 126,573 | 1,181,248 ± 25,335 | +10.72% | 3,872→3,232 | 7,360→4,736 | Inconclusive: below 3× baseline MAD |
| UDP 1200 B | 137,004 ± 3,322 | 141,957 ± 2,122 | +3.62% | 2,112→2,080 | 2,720→2,912 | Inconclusive |
| UDP 65507 B | 62,131 ± 821 | 64,735 ± 563 | +4.19% | 4,864→4,480 | 7,168→6,080 | Inconclusive: below 5% threshold |
| TCP 128 B, 1024 sessions | 226,340 ± 2,595 | 221,147 ± 11,040 | −2.29% | 6,016→7,360 | 9,472→15,744 | Inconclusive; watch tail behavior |
| TCP 128 B, 4096 sessions | 150,780 ± 2,985 | 204,813 ± 4,776 | +35.84% | 36,864→26,368 | 77,824→92,160 | Rejected as a performance claim after A/B/A |

The acceptance threshold is `max(5% × baseline median, 3 × baseline MAD)` in echoes/s, with no meaningful tail regression elsewhere. No candidate constitutes an accepted hot-path optimization. The p99/p999 figures are coarse batch-level approximations, not a precise latency probe; none is a defensible tail-latency improvement claim. The 1024-session p999 increase and 4096-session p999 increase especially preclude claiming an unqualified latency win.

The apparent 4096-session gain failed an immediate A/B/A check using the **original immutable baseline executable** on the same machine and workload with seven valid independently stopped runs per set:

| Set | Median echoes/s | MAD echoes/s | Median elapsed ms | Median batch p99 µs ~ | Median batch p999 µs ~ |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1, original baseline | 150,780 | 2,985 | 21,223 | 36,864 | 77,824 |
| B, structural candidate | 204,813 | 4,776 | 15,624 | 26,368 | 92,160 |
| A2, original baseline rerun | 212,922 | 6,390 | 15,029 | 23,808 | 84,992 |

The unchanged A2 binary outperformed B; the earlier apparent gain was confounded by time-varying machine conditions. Candidate 4096-session seven-run **continuous-server** longevity also passed 7/7, whereas the earlier baseline continuous-server series failed on run 7. This is a non-reproduction, not proof of a fixed root cause.

Raw candidate archive (six formal workloads plus the continuous-server longevity series): `zig-out/bench/candidate-562d70f/raw-samples-2026-10-01.zip`, SHA-256 `843100bdc60e457b0a000fd4d692875ac7f36c3921d9d20f2003e0f4217b3b26`. Raw A2 archive: `zig-out/bench/baseline/aba-recheck-2026-10-01.zip`, SHA-256 `98aac2ac1d8640ab2c59bf4267a51b1d865227367f4ce375c00b1961a1c6fd97`. Both are ignored local artifacts, not committed.

The full pinned-2375 Debug and ReleaseFast suites pass, including TCP storm, capacity reuse, fault/process tests, UDP stop/drain and SDK ABI contract. External Zig and C++ clients each passed TCP `/k 8` full batch, TCP `100003` non-integral tail, UDP 1200 B, and UDP 65507 B against the candidate server (8/8). Each server ran without `/w`, then exited 0 after Ctrl+Break with terminal zero active/outstanding. The interop log archive is `zig-out/bench/candidate-562d70f/interop-logs-2026-10-01.zip`, SHA-256 `67328a75f547a73fc430e98291b475cba7db4c350c58948caab3391b141b16ee`. The interop peer executable SHA-256 values were Zig client `cd7109334de2b2564e1f3a01aa8a5802c8de2d1d805bcf7b70e0ecac1214e340` and C++ client `cc1da02d9455a27509068ccf5439b92bdfb3e6fe4851bb92a2804ceb79ade80a`; their source/build provenance is not inferred from these hashes.

The final review reran those eight candidate-server cases after adding a timeout-child cleanup contract: all 8/8 passed with the same server binary SHA-256. The separately built C++ server also passed all eight cases against those same two client binaries (8/8). The review contract proved a timed-out child process is terminated and reaped rather than only disposing its process object; both pinned-2375 Debug and ReleaseFast full suites passed with that contract wired into `build.zig`.

The candidate establishes a safer ownership/setup lifecycle with preserved RIO + IOCP behavior. It does **not** establish a measured performance gain. A profile-guided hot-path change remains future work if a repeatable server-side hotspot is found on the target deployment hardware.
