param(
    [string]$DriverPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-server-fault-driver.exe')
)

$ErrorActionPreference = 'Stop'
$driver = (Resolve-Path -LiteralPath $DriverPath).Path
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-echo-server-faults-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $expected = @{
        notify_failure = 'RIONotify(worker)'
        corrupt_cq = 'RIODequeueCompletion(worker)'
        invalid_transition = 'worker notification rearm transition'
        control_post_failure = 'PostQueuedCompletionStatus(worker stop)'
    }
    foreach ($mode in @('notify_failure', 'corrupt_cq', 'invalid_transition', 'control_post_failure')) {
        $stdout = Join-Path $scratch "$mode.stdout.txt"
        $stderr = Join-Path $scratch "$mode.stderr.txt"
        $process = Start-Process -FilePath $driver -ArgumentList @($mode) -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($process.ExitCode -ne 4) { throw "$mode exited $($process.ExitCode), expected 4." }
        $output = Get-Content -Raw -LiteralPath $stdout
        $errorOutput = Get-Content -Raw -LiteralPath $stderr
        if ($output.Length -ne 0) { throw "$mode unexpectedly wrote stdout: $output" }
        if (-not $errorOutput.Contains($expected[$mode]) -or $errorOutput -notmatch 'native_error=\d+') { throw "$mode stderr mismatch: $errorOutput" }
    }
    Write-Host 'fault_process_tests: PASS'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
