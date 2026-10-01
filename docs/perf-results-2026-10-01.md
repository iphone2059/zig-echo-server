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

`wpr -start CPU -filemode` failed before collection with `0xc5585011` (`Failed to enable the policy to profile system performance`). No CPU-stack profile or server-side hotspot evidence exists yet. Worker handoff, CQ batch size/connection layout, and UDP slot/repost changes remain profile-gated; do not invent a hotspot from throughput alone.

An existing independently built C++ server executable is available at `cpp-echo-server/build/release/cpp-echo-server.exe`, SHA-256 `393a0616c55faabdba6812f3b82bff6a8eda9bc13cfb6235fe505dae92f04d38`. Its exact build-source provenance was not established by the no-op incremental build, so it is not part of the Zig acceptance baseline or the table above. Cross-project interoperability will be tested separately.

## Candidate decisions

Pending typed-owner and synchronous-initialization refactor, self-contained tests, interop, and comparable post-change validation. No optimization accepted, rejected, or claimed yet.
