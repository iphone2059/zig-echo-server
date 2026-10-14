param(
    [string]$DriverPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-server-fault-driver.exe'),
    [int]$TimeoutMilliseconds = 10000
)

$ErrorActionPreference = 'Stop'
$driver = (Resolve-Path -LiteralPath $DriverPath).Path
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-echo-server-faults-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null

# Every boundary is driven in its own child process and waited for with a bound. An unbounded wait
# would let a boundary that never terminates hang the whole gate instead of failing it.
function Invoke-Fault([string]$Mode, [string]$Stdout, [string]$Stderr) {
    $process = Start-Process -FilePath $driver -ArgumentList @($Mode) -PassThru -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    try {
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw "$Mode did not reach its boundary within $TimeoutMilliseconds ms." }
        return $process.ExitCode
    } finally {
        try {
            if (-not $process.HasExited) { $process.Kill($true); if (-not $process.WaitForExit(5000)) { throw "$Mode cleanup timeout." } }
        } finally { $process.Dispose() }
    }
}

try {
    foreach ($mode in @('handoff_positive','handoff_invalid')) {
        $stdout = Join-Path $scratch "$mode.stdout.txt"
        $stderr = Join-Path $scratch "$mode.stderr.txt"
        $exitCode = Invoke-Fault -Mode $mode -Stdout $stdout -Stderr $stderr
        $expectedExit = if ($mode -eq 'handoff_positive') { 0 } else { 4 }
        $errorOutput = [string](Get-Content -Raw -LiteralPath $stderr)
        if ($exitCode -ne $expectedExit) { throw "$mode exited $exitCode, expected ${expectedExit}: $errorOutput" }
        if ([string](Get-Content -Raw -LiteralPath $stdout)) { throw "$mode unexpectedly wrote stdout" }
        if ($mode -eq 'handoff_positive') {
            if (-not [string]::IsNullOrWhiteSpace($errorOutput)) { throw "$mode unexpectedly wrote stderr: $errorOutput" }
        } elseif ($errorOutput -notmatch '(?m)^AcceptEx handoff invariant failed: native_error=10038\r?$') { throw "$mode lost exact invariant diagnostic: $errorOutput" }
    }
    $expected = @{
        notify_failure = 'RIONotify(worker)'
        corrupt_cq = 'RIODequeueCompletion(worker)'
        invalid_transition = 'worker notification rearm transition'
        control_post_failure = 'PostQueuedCompletionStatus(worker stop)'
        worker_undrained = 'TCP worker release precondition'
        acceptor_ownership = 'TCP acceptor terminal operations'
    }
    foreach ($mode in @('notify_failure','corrupt_cq','invalid_transition','control_post_failure','worker_undrained','acceptor_ownership')) {
        $stdout = Join-Path $scratch "$mode.stdout.txt"
        $stderr = Join-Path $scratch "$mode.stderr.txt"
        $exitCode = Invoke-Fault -Mode $mode -Stdout $stdout -Stderr $stderr
        if ($exitCode -ne 4) { throw "$mode exited $exitCode, expected 4." }
        $output = Get-Content -Raw -LiteralPath $stdout
        $errorOutput = Get-Content -Raw -LiteralPath $stderr
        if ($output.Length -ne 0) { throw "$mode unexpectedly wrote stdout: $output" }
        # The status is a signed decimal, as the C++ %d and the Rust {} both print it, so a negative
        # Win32 status is in scope; the boundary name and a numeric payload are what must be present.
        if (-not $errorOutput.Contains($expected[$mode]) -or $errorOutput -notmatch 'native_error=-?\d+') { throw "$mode stderr mismatch: $errorOutput" }
    }

    # The acceptor case is also an ordering proof, not just an exit code. Its state array lives on the
    # stack and its operation table is empty, so a release that ran before the ownership check would
    # free a non-heap address and could not produce this clean, named boundary. Reaching the stage name
    # with exit 4 therefore shows the invariant is decided before anything is released.
    $acceptorStderr = Get-Content -Raw -LiteralPath (Join-Path $scratch 'acceptor_ownership.stderr.txt')
    if ($acceptorStderr -notmatch 'TCP acceptor terminal operations failed: native_error=996') {
        throw "acceptor ownership boundary lost its identity: $acceptorStderr"
    }
    # The positive control for the startup case: a worker that never produced a thread must pass the
    # same guard that a joined, undrained worker fails. Without this the fail-fast above could be
    # satisfied by a guard that rejects every input.
    $notStartedStdout = Join-Path $scratch 'worker_not_started.stdout.txt'
    $notStartedStderr = Join-Path $scratch 'worker_not_started.stderr.txt'
    $notStartedExit = Invoke-Fault -Mode 'worker_not_started' -Stdout $notStartedStdout -Stderr $notStartedStderr
    if ($notStartedExit -ne 0) { throw "worker_not_started exited $notStartedExit, expected 0." }
    $notStartedError = Get-Content -Raw -LiteralPath $notStartedStderr
    if ($notStartedError.Length -ne 0) { throw "worker_not_started wrote stderr: $notStartedError" }

    # The end-to-end partial startup: four workers, the third never gets a thread. A clean bounded
    # exit is the assertion -- the two threads that did start were joined before anything was
    # released, and the worker whose storage exists without a thread was released without touching
    # uninitialised native state. A release that ran before the joins could not produce this.
    $partialStdout = Join-Path $scratch 'partial_worker_start.stdout.txt'
    $partialStderr = Join-Path $scratch 'partial_worker_start.stderr.txt'
    $partialExit = Invoke-Fault -Mode 'partial_worker_start' -Stdout $partialStdout -Stderr $partialStderr
    if ($partialExit -ne 2) { throw "partial_worker_start exited $partialExit, expected 2 (network)." }
    $partialError = Get-Content -Raw -LiteralPath $partialStderr
    if (-not $partialError.Contains('CreateThread(worker)')) { throw "partial_worker_start stderr mismatch: $partialError" }
    $partialOutput = ((Get-Content -Raw -LiteralPath $partialStdout) -replace '\s+',' ').Trim()
    if ($partialOutput -notmatch 'workers=2\b') { throw "partial_worker_start must report the two threads it started: $partialOutput" }

    Write-Host 'fault_process_tests: PASS'
}
finally {
    $resolvedScratch = [System.IO.Path]::GetFullPath($scratch)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fault scratch escaped the temporary directory' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
