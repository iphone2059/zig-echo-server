param(
    [Parameter(Mandatory=$true)][string]$ServerPath,
    [Parameter(Mandatory=$true)][int]$ServerPid,
    [Parameter(Mandatory=$true)][string[]]$ServerArguments,
    [Parameter(Mandatory=$true)][string]$ClientPath,
    [Parameter(Mandatory=$true)][ValidateRange(1,65535)][int]$Port,
    [Parameter(Mandatory=$true)][string]$Case,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$Label,
    [string]$ExpectedServerSha256,
    [string]$HostAddress='127.0.0.1',
    [long]$EchoCountOverride=0,
    [switch]$Pilot,
    [switch]$DescribeOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'perf_commands.ps1')

$manifest=@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'perf_workloads.json') -Raw | ConvertFrom-Json)
$selected=@($manifest | Where-Object { $_.name -ceq $Case })
if ($selected.Count -ne 1) { throw "benchmark case missing or duplicated: $Case" }
$workload=$selected[0].PSObject.Copy()
if ($EchoCountOverride -lt 0) { throw 'pilot echo count must be positive' }
if ($EchoCountOverride -gt 0) { $workload.echo_count=$EchoCountOverride }
$clientArguments=@(New-ClientArguments -Case $workload -Port $Port -HostAddress $HostAddress)
$expectedServerArguments=@(New-ServerArguments -Case $workload -Port $Port)
if (($ServerArguments -join '|') -cne ($expectedServerArguments -join '|')) { throw 'declared server arguments do not match workload' }
if ($DescribeOnly) {
    [pscustomobject]@{ case=$Case; client_arguments=[string[]]$clientArguments; server_arguments=[string[]]$expectedServerArguments }
    return
}
if ($Label -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'label must contain letters, digits, _ or -' }
if ($ExpectedServerSha256 -cnotmatch '^[A-Fa-f0-9]{64}$') { throw 'expected server SHA-256 is required for live runs' }

$serverExe=(Resolve-Path -LiteralPath $ServerPath -ErrorAction Stop).Path
$clientExe=(Resolve-Path -LiteralPath $ClientPath -ErrorAction Stop).Path
$serverCommit=Get-ExecutableCommit -Path $serverExe
$clientCommit=Get-ExecutableCommit -Path $clientExe
$serverProcess=Get-Process -Id $ServerPid -ErrorAction Stop
try {
    if (-not [string]::Equals([IO.Path]::GetFullPath($serverProcess.Path),[IO.Path]::GetFullPath($serverExe),[StringComparison]::OrdinalIgnoreCase)) {
        throw "server PID $ServerPid is not $serverExe"
    }
    $serverHash=(Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::Equals($serverHash,$ExpectedServerSha256,[StringComparison]::OrdinalIgnoreCase)) { throw 'server SHA-256 changed' }
} finally { $serverProcess.Dispose() }

$runId='{0}-{1}-{2}-{3}' -f $Label,$Case,[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'),[guid]::NewGuid().ToString('N')
$runDirectory=Join-Path (Join-Path $OutputDirectory $Label) $runId
$null=New-Item -ItemType Directory -Path $runDirectory -Force
$stdoutPath=Join-Path $runDirectory 'client.stdout.txt'
$stderrPath=Join-Path $runDirectory 'client.stderr.txt'
$metadataPath=Join-Path $runDirectory 'run.json'
$timer=[Diagnostics.Stopwatch]::StartNew()
$process=Start-Process -FilePath $clientExe -ArgumentList $clientArguments -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
$timedOut=$false
try {
    if (-not $process.WaitForExit(600000)) {
        $timedOut=$true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
    $timer.Stop()
    $cpuMilliseconds=try { [math]::Round($process.TotalProcessorTime.TotalMilliseconds,3) } catch { $null }
    $exitCode=if ($timedOut) { -1 } else { $process.ExitCode }
} finally { $process.Dispose() }

$stdout=Get-Content -LiteralPath $stdoutPath -Raw
$stderr=Get-Content -LiteralPath $stderrPath -Raw
if ($null -eq $stdout) { $stdout='' }
if ($null -eq $stderr) { $stderr='' }
$final=@(($stdout -split "`r?`n") | Where-Object { $_ -match '^final ' } | Select-Object -Last 1)
$fields=@{}
if ($final.Count -eq 1) {
    foreach ($matchValue in [regex]::Matches($final[0],'([A-Za-z_]+)=([^\s]+)')) {
        $fields[$matchValue.Groups[1].Value]=$matchValue.Groups[2].Value
    }
}
$serverProcess=Get-Process -Id $ServerPid -ErrorAction SilentlyContinue
$serverAlive=$false
if ($null -ne $serverProcess) {
    try { $serverAlive=-not $serverProcess.HasExited -and
        [string]::Equals([IO.Path]::GetFullPath($serverProcess.Path),[IO.Path]::GetFullPath($serverExe),[StringComparison]::OrdinalIgnoreCase) }
    finally { $serverProcess.Dispose() }
}
$observedServerHash=(Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedBytes=[long]$workload.echo_count * [long]$workload.payload_bytes
$benchLine=@(($stdout -split "`r?`n") | Where-Object { $_ -match '^bench_latency_sample=batch ' } | Select-Object -Last 1)
$run=[pscustomobject]@{
    case=$workload; exit_code=$exitCode; elapsed_ms=[long]$timer.ElapsedMilliseconds
    process_cpu_ms=$cpuMilliseconds; timed_out=$timedOut; pilot=[bool]$Pilot
    echoed=if ($fields.ContainsKey('echoed')) { [long]$fields.echoed } else { -1 }
    expected_echo_count=[long]$workload.echo_count
    bytes=if ($fields.ContainsKey('bytes')) { [long]$fields.bytes } else { -1 }
    expected_bytes=$expectedBytes
    lost=if ($fields.ContainsKey('lost')) { [long]$fields.lost } else { -1 }
    corrupted=if ($fields.ContainsKey('corrupted')) { [long]$fields.corrupted } else { -1 }
    network_errors=if ($fields.ContainsKey('network_errors')) { [long]$fields.network_errors } else { -1 }
    reported_elapsed_ms=if ($fields.ContainsKey('elapsed_ms')) { [long]$fields.elapsed_ms } else { -1 }
    bench_latency_line=if ($benchLine.Count -eq 1) { $benchLine[0] } else { $null }
    stderr_length=$stderr.Length; server_alive_after_run=$serverAlive
    server_sha256=$observedServerHash; expected_server_sha256=$ExpectedServerSha256.ToLowerInvariant()
    client_sha256=(Get-FileHash -LiteralPath $clientExe -Algorithm SHA256).Hash.ToLowerInvariant()
    server_path=$serverExe; expected_server_path=$serverExe; client_path=$clientExe; server_pid=$ServerPid
    server_commit=$serverCommit; client_commit=$clientCommit
    server_arguments=$ServerArguments; client_arguments=$clientArguments; host_address=$HostAddress
    zig_version=(& 'C:\bin\zig-x86_64-windows-0.17.0-dev.2375+d8aab4878\zig.exe' version | Out-String).Trim()
    windows_version=[Environment]::OSVersion.VersionString
    processor=@(Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name -Unique)
    stdout_path=$stdoutPath; stderr_path=$stderrPath
}
$correctnessValid=$run.exit_code -eq 0 -and $run.echoed -eq $run.expected_echo_count -and
    $run.bytes -eq $run.expected_bytes -and $run.lost -eq 0 -and $run.corrupted -eq 0 -and
    $run.network_errors -eq 0 -and $run.stderr_length -eq 0 -and $run.server_alive_after_run -and
    [string]::Equals($run.server_sha256,$run.expected_server_sha256,[StringComparison]::OrdinalIgnoreCase)
$run | Add-Member -NotePropertyName correctness_valid -NotePropertyValue $correctnessValid
$run | Add-Member -NotePropertyName provisional_valid -NotePropertyValue ($correctnessValid -and $run.elapsed_ms -ge 10000)
$run | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding utf8
Write-Output "benchmark_run=$metadataPath provisional_valid=$($run.provisional_valid) elapsed_ms=$($run.elapsed_ms) echoed=$($run.echoed)"
if (-not $run.provisional_valid -and -not ($Pilot -and $correctnessValid)) { throw "invalid provisional server benchmark run; inspect $metadataPath" }
