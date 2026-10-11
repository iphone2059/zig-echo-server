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
    $process = Start-Process -FilePath $driver -ArgumentList @($Mode) -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        Stop-Process -Id $process.Id -Force
        throw "$Mode did not reach its boundary within $TimeoutMilliseconds ms."
    }
    return $process.ExitCode
}

try {
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
        if (-not $errorOutput.Contains($expected[$mode]) -or $errorOutput -notmatch 'native_error=\d+') { throw "$mode stderr mismatch: $errorOutput" }
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

    Write-Host 'fault_process_tests: PASS'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
