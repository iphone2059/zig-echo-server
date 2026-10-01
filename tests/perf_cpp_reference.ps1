param(
    [Parameter(Mandatory=$true)][string]$ServerPath,
    [Parameter(Mandatory=$true)][string]$ClientPath,
    [Parameter(Mandatory=$true)][string]$Case,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [switch]$DescribeOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'perf_commands.ps1')
. (Join-Path $PSScriptRoot 'interop_child_lifecycle.ps1')

$manifest=@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'perf_workloads.json') -Raw | ConvertFrom-Json)
$selected=@($manifest | Where-Object { $_.name -ceq $Case })
if ($selected.Count -ne 1) { throw "C++ reference case missing or duplicated: $Case" }
$workload=$selected[0]
if ($DescribeOnly) {
    [pscustomobject]@{
        reference_only=$true; server_source_commit=$null; case=$Case
        server_arguments=@(New-ServerArguments -Case $workload -Port 7000)
        client_arguments=@(New-ClientArguments -Case $workload -Port 7000)
    }
    return
}

$serverExe=(Resolve-Path -LiteralPath $ServerPath).Path
$clientExe=(Resolve-Path -LiteralPath $ClientPath).Path
$serverHash=(Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash.ToLowerInvariant()
$clientHash=(Get-FileHash -LiteralPath $clientExe -Algorithm SHA256).Hash.ToLowerInvariant()
$clientCommit=Get-ExecutableCommit -Path $clientExe
if ($workload.protocol -ceq 'tcp') {
    $reservation=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $reservation.Start()
    try { $port=([Net.IPEndPoint]$reservation.LocalEndpoint).Port }
    finally { $reservation.Stop() }
} else {
    $reservation=[Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0))
    try { $port=([Net.IPEndPoint]$reservation.Client.LocalEndPoint).Port }
    finally { $reservation.Dispose() }
}
$serverArguments=@(New-ServerArguments -Case $workload -Port $port)
$clientArguments=@(New-ClientArguments -Case $workload -Port $port)
$runDirectory=Join-Path $OutputDirectory ('cpp-reference-{0}-{1}' -f $Case,[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $runDirectory -Force
$serverStdout=Join-Path $runDirectory 'server.stdout.txt'
$serverStderr=Join-Path $runDirectory 'server.stderr.txt'
$clientStdout=Join-Path $runDirectory 'client.stdout.txt'
$clientStderr=Join-Path $runDirectory 'client.stderr.txt'
$server=Start-Process -FilePath $serverExe -ArgumentList $serverArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
try {
    Start-Sleep -Milliseconds 500
    if ($server.HasExited) { throw "C++ reference server exited during startup: $runDirectory" }
    $client=Start-Process -FilePath $clientExe -ArgumentList $clientArguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $clientStdout -RedirectStandardError $clientStderr
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        Wait-InteropChild -Process $client -TimeoutMilliseconds 120000 -Description "C++ reference $Case"
        $timer.Stop()
        $clientExit=$client.ExitCode
        $clientCpuMs=[math]::Round($client.TotalProcessorTime.TotalMilliseconds,3)
    } finally { $client.Dispose() }
    $stdout=Get-Content -LiteralPath $clientStdout -Raw
    $stderr=Get-Content -LiteralPath $clientStderr -Raw
    if ($null -eq $stdout) { $stdout='' }
    if ($null -eq $stderr) { $stderr='' }
    $final=@(($stdout -split "`r?`n") | Where-Object { $_ -match '^final ' } | Select-Object -Last 1)
    $fields=@{}
    if ($final.Count -eq 1) {
        foreach ($matched in [regex]::Matches($final[0],'([A-Za-z_]+)=([^\s]+)')) {
            $fields[$matched.Groups[1].Value]=$matched.Groups[2].Value
        }
    }
    $expectedBytes=[long]$workload.echo_count * [long]$workload.payload_bytes
    $correctness=$clientExit -eq 0 -and $stderr.Length -eq 0 -and $timer.ElapsedMilliseconds -ge 10000 -and
        $fields.ContainsKey('echoed') -and [long]$fields.echoed -eq [long]$workload.echo_count -and
        $fields.ContainsKey('bytes') -and [long]$fields.bytes -eq $expectedBytes -and
        $fields.ContainsKey('lost') -and [long]$fields.lost -eq 0 -and
        $fields.ContainsKey('corrupted') -and [long]$fields.corrupted -eq 0 -and
        $fields.ContainsKey('network_errors') -and [long]$fields.network_errors -eq 0 -and
        -not $server.HasExited
    if (-not $correctness) { throw "invalid C++ reference client run: $runDirectory" }
    $null=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'perf_console_stop.ps1') `
        -ServerPid $server.Id -ServerPath $serverExe -ExpectedServerSha256 $serverHash `
        -Protocol $workload.protocol -WorkerCount $(if ($workload.protocol -ceq 'tcp') { [int]$workload.threads } else { 0 }) `
        -StdoutPath $serverStdout -StderrPath $serverStderr -OutputDirectory $runDirectory
    if ($LASTEXITCODE -ne 0) { throw "C++ reference server did not stop normally: $runDirectory" }
    $stopPath=@(Get-ChildItem -LiteralPath $runDirectory -Filter 'stop-*.json' -File | Select-Object -Last 1)
    if ($stopPath.Count -ne 1) { throw "C++ reference stop record missing: $runDirectory" }
    $stop=Get-Content -LiteralPath $stopPath[0].FullName -Raw | ConvertFrom-Json
    if (-not $stop.valid) { throw "invalid C++ reference terminal drain: $runDirectory" }
    $record=[pscustomobject]@{
        reference_only=$true; acceptance_eligible=$false; server_source_commit=$null
        client_source_commit=$clientCommit; case=$workload; server_sha256=$serverHash; client_sha256=$clientHash
        server_path=$serverExe; client_path=$clientExe; server_arguments=$serverArguments; client_arguments=$clientArguments
        client_exit_code=$clientExit; elapsed_ms=[long]$timer.ElapsedMilliseconds; process_cpu_ms=$clientCpuMs
        echoed=[long]$fields.echoed; bytes=[long]$fields.bytes; lost=[long]$fields.lost
        corrupted=[long]$fields.corrupted; network_errors=[long]$fields.network_errors
        client_final=$final[0]; client_stdout=$clientStdout; client_stderr=$clientStderr
        server_stdout=$serverStdout; server_stderr=$serverStderr; stop_record=$stopPath[0].FullName
        windows_version=[Environment]::OSVersion.VersionString; recorded_at_utc=[DateTime]::UtcNow.ToString('o')
    }
    $metadata=Join-Path $runDirectory 'reference.json'
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadata -Encoding utf8
    Write-Output "cpp_reference=$metadata elapsed_ms=$($record.elapsed_ms) echoed=$($record.echoed) server_sha256=$serverHash"
} finally {
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
        Write-Warning "C++ reference server force-stopped after incomplete run: $runDirectory"
    }
    $server.Dispose()
}
