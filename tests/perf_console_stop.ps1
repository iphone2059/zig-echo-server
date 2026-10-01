param(
    [Parameter(Mandatory=$true)][int]$ServerPid,
    [Parameter(Mandatory=$true)][string]$ServerPath,
    [Parameter(Mandatory=$true)][string]$ExpectedServerSha256,
    [Parameter(Mandatory=$true)][ValidateSet('tcp','udp')][string]$Protocol,
    [Parameter(Mandatory=$true)][int]$WorkerCount,
    [Parameter(Mandatory=$true)][string]$StdoutPath,
    [Parameter(Mandatory=$true)][string]$StderrPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'

if ($null -eq ('BenchConsoleSignals' -as [type])) {
    Add-Type @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class BenchConsoleSignals {
    private delegate bool HandlerRoutine(uint kind);
    private static HandlerRoutine handler = Ignore;
    private static bool Ignore(uint kind) { return true; }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint GetConsoleProcessList([Out] uint[] ids, uint capacity);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GenerateConsoleCtrlEvent(uint kind, uint groupId);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool SetConsoleCtrlHandler(HandlerRoutine callback, bool add);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    public static int SendBreakToIsolatedConsole(uint targetPid) {
        FreeConsole();
        if (!AttachConsole(targetPid)) return Marshal.GetLastWin32Error();
        try {
            uint[] ids = new uint[16];
            uint count = GetConsoleProcessList(ids, (uint)ids.Length);
            bool targetFound = false, selfFound = false;
            for (uint i = 0; i < count && i < ids.Length; i++) {
                if (ids[i] == targetPid) targetFound = true;
                if (ids[i] == (uint)Process.GetCurrentProcess().Id) selfFound = true;
            }
            // Never broadcast into a console containing the caller or unrelated processes.
            if (count != 2 || !targetFound || !selfFound) return -100;
            if (!SetConsoleCtrlHandler(handler, true)) return Marshal.GetLastWin32Error();
            if (!GenerateConsoleCtrlEvent(1, 0)) return Marshal.GetLastWin32Error();
            Thread.Sleep(100);
            return 0;
        } finally { FreeConsole(); }
    }
}
'@
}
$serverExe=(Resolve-Path -LiteralPath $ServerPath -ErrorAction Stop).Path
$serverHash=(Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not [string]::Equals($serverHash,$ExpectedServerSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'server SHA-256 changed before stop' }
$process=Get-Process -Id $ServerPid -ErrorAction Stop
try {
    if (-not [string]::Equals([IO.Path]::GetFullPath($process.Path),[IO.Path]::GetFullPath($serverExe),[StringComparison]::OrdinalIgnoreCase)) {
        throw "server PID $ServerPid is not $serverExe"
    }
    $nativeHandle=$process.Handle
    $result=[BenchConsoleSignals]::SendBreakToIsolatedConsole([uint32]$ServerPid)
    if ($result -ne 0) { throw "isolated console stop failed: $result" }
    if (-not $process.WaitForExit(30000)) { throw 'server did not converge within 30 seconds after CTRL_BREAK_EVENT' }
    [uint32]$nativeExitCode=0
    if (-not [BenchConsoleSignals]::GetExitCodeProcess($nativeHandle,[ref]$nativeExitCode)) { throw 'GetExitCodeProcess failed after graceful stop' }
    $exitCode=[int]$nativeExitCode
} finally { $process.Dispose() }

$stdout=Get-Content -LiteralPath $StdoutPath -Raw
$stderr=Get-Content -LiteralPath $StderrPath -Raw
if ($null -eq $stdout) { $stdout='' }
if ($null -eq $stderr) { $stderr='' }
$terminal=@(($stdout -split "`r?`n") | Where-Object { $_ -match '^final ' } | Select-Object -Last 1)
$workerLines=@(($stdout -split "`r?`n") | Where-Object { $_ -match '^\[worker \d+\] ' })
$zeroWorkers=@($workerLines | Where-Object { $_ -match '\bactive=0$' })
$record=[pscustomobject]@{
    protocol=$Protocol; exit_code=$exitCode; stderr_length=$stderr.Length
    terminal_line=if ($terminal.Count -eq 1) { $terminal[0] } else { '' }
    worker_count=$workerLines.Count; zero_workers=$zeroWorkers.Count; expected_worker_count=$WorkerCount
    server_pid=$ServerPid; server_path=$serverExe; server_sha256=$serverHash
    stdout_path=$StdoutPath; stderr_path=$StderrPath
    stopped_at_utc=[DateTime]::UtcNow.ToString('o')
}
$record | Add-Member -NotePropertyName valid -NotePropertyValue (
    $record.exit_code -eq 0 -and $record.stderr_length -eq 0 -and (
        ($Protocol -ceq 'tcp' -and $record.terminal_line -match '^final protocol=tcp\b.*\bactive=0$' -and
            $record.worker_count -eq $WorkerCount -and $record.zero_workers -eq $WorkerCount) -or
        ($Protocol -ceq 'udp' -and $record.terminal_line -match '^final protocol=udp\b.*\boutstanding=0$')))
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$path=Join-Path $OutputDirectory ('stop-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'.json')
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
Write-Output "benchmark_stop=$path valid=$($record.valid) exit=$($record.exit_code)"
if (-not $record.valid) { throw "invalid terminal server stop; inspect $path" }
