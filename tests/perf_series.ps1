param(
    [Parameter(Mandatory=$true)][string]$ServerPath,
    [Parameter(Mandatory=$true)][string]$ClientPath,
    [Parameter(Mandatory=$true)][string]$Case,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$Label,
    [ValidateRange(1,20)][int]$Runs=7,
    [switch]$Pilot
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'perf_commands.ps1')
$serverExe=(Resolve-Path -LiteralPath $ServerPath -ErrorAction Stop).Path
$clientExe=(Resolve-Path -LiteralPath $ClientPath -ErrorAction Stop).Path
$serverHash=(Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'perf_workloads.json') -Raw | ConvertFrom-Json)
$selected=@($manifest | Where-Object { $_.name -ceq $Case })
if ($selected.Count -ne 1) { throw "benchmark case missing or duplicated: $Case" }
$workload=$selected[0]
if ($Label -cnotmatch '^[A-Za-z0-9_-]+$') { throw 'label must contain letters, digits, _ or -' }

if ($workload.protocol -ceq 'tcp') {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try { $port=([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
} else {
    $socket=[Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0))
    try { $port=([Net.IPEndPoint]$socket.Client.LocalEndPoint).Port }
    finally { $socket.Dispose() }
}
$serverArguments=@(New-ServerArguments -Case $workload -Port $port)
$seriesId='{0}-{1}-{2}-{3}' -f $Label,$Case,[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'),[guid]::NewGuid().ToString('N')
$seriesDirectory=Join-Path $OutputDirectory $seriesId
$null=New-Item -ItemType Directory -Path $seriesDirectory -Force
$serverStdout=Join-Path $seriesDirectory 'server.stdout.txt'
$serverStderr=Join-Path $seriesDirectory 'server.stderr.txt'
$process=Start-Process -FilePath $serverExe -ArgumentList $serverArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
$runPaths=[Collections.Generic.List[string]]::new()
$frozenCount=[long]$workload.echo_count
$seriesCompleted=$false
try {
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) { throw "server exited during startup: exit=$($process.ExitCode) stderr=$(Get-Content -LiteralPath $serverStderr -Raw)" }
    if (-not $Pilot) {
        $warmupArguments=@{
            ServerPath=$serverExe; ServerPid=$process.Id; ServerArguments=$serverArguments; ClientPath=$clientExe
            ExpectedServerSha256=$serverHash; Port=$port; Case=$Case; OutputDirectory=$seriesDirectory
            Label='warmup'; EchoCountOverride=100000; Pilot=$true
        }
        $null=& (Join-Path $PSScriptRoot 'perf_loopback.ps1') @warmupArguments
    }
    $iteration=0
    do {
        $iteration++
        $arguments=@{
            ServerPath=$serverExe; ServerPid=$process.Id; ServerArguments=$serverArguments; ClientPath=$clientExe
            ExpectedServerSha256=$serverHash; Port=$port; Case=$Case; OutputDirectory=$seriesDirectory
            Label=if ($Pilot) { 'pilot' } else { 'measured' }
        }
        if ($Pilot) { $arguments.EchoCountOverride=$frozenCount; $arguments.Pilot=$true }
        $output=& (Join-Path $PSScriptRoot 'perf_loopback.ps1') @arguments
        $line=@($output | Where-Object { $_ -match '^benchmark_run=' } | Select-Object -Last 1)
        if ($line.Count -ne 1 -or $line[0] -notmatch '^benchmark_run=(.*?) provisional_valid=') { throw "runner did not return metadata path: $output" }
        $path=$Matches[1]
        $runPaths.Add($path)
        $run=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Write-Output "series=$seriesId iteration=$iteration count=$($run.expected_echo_count) elapsed_ms=$($run.elapsed_ms) provisional_valid=$($run.provisional_valid)"
        if ($Pilot -and $run.elapsed_ms -lt 10000) {
            if ($frozenCount -gt [long]::MaxValue / 2) { throw 'pilot echo count overflow' }
            $frozenCount*=2
        }
    } while (($Pilot -and $run.elapsed_ms -lt 10000) -or ((-not $Pilot) -and $iteration -lt $Runs))
    if ($Pilot -and $run.elapsed_ms -lt 10000) { throw 'pilot never reached the 10-second minimum' }

    $null=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'perf_console_stop.ps1') `
        -ServerPid $process.Id -ServerPath $serverExe -ExpectedServerSha256 $serverHash `
        -Protocol $workload.protocol -WorkerCount $(if ($workload.protocol -ceq 'tcp') { [int]$workload.threads } else { 0 }) `
        -StdoutPath $serverStdout -StderrPath $serverStderr -OutputDirectory $seriesDirectory
    if ($LASTEXITCODE -ne 0) { throw 'graceful console stop failed' }
    $stopPath=@(Get-ChildItem -LiteralPath $seriesDirectory -Filter 'stop-*.json' -File | Sort-Object LastWriteTime | Select-Object -Last 1)
    if ($stopPath.Count -ne 1) { throw 'server stop record missing' }
    $stop=Get-Content -LiteralPath $stopPath[0].FullName -Raw | ConvertFrom-Json
    if (-not $stop.valid) { throw 'server did not terminate with zero outstanding state' }
    foreach ($path in $runPaths) {
        $run=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($Pilot) {
            if (-not $run.correctness_valid) { throw "pilot correctness failure: $path" }
        } elseif (-not (Test-BenchmarkRun -Run $run -StopRecord $stop)) { throw "final benchmark validity failure: $path" }
    }
    $seriesCompleted=$true
    Write-Output "series_complete=$seriesDirectory valid_runs=$($runPaths.Count) frozen_count=$frozenCount stop=$($stopPath[0].FullName)"
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        Write-Warning "benchmark server was force-stopped after an invalid/incomplete series: $seriesDirectory"
    }
    $process.Dispose()
}
if (-not $seriesCompleted) { exit 1 }
