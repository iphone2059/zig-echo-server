$ErrorActionPreference = 'Stop'
$commands = Join-Path $PSScriptRoot 'perf_commands.ps1'
if (Test-Path -LiteralPath $commands -PathType Leaf) { . $commands }
function Assert-True([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }

Assert-True ($null -ne (Get-Command New-ClientArguments -ErrorAction SilentlyContinue)) 'New-ClientArguments is missing'
Assert-True ($null -ne (Get-Command New-ServerArguments -ErrorAction SilentlyContinue)) 'New-ServerArguments is missing'
Assert-True ($null -ne (Get-Command Test-BenchmarkRun -ErrorAction SilentlyContinue)) 'Test-BenchmarkRun is missing'
$threw = $false
try { $null = Get-ExecutableCommit -Path $commands } catch { $threw = $true }
Assert-True $threw 'binary provenance must not fall back to the current repository HEAD'

$tcp = [pscustomobject]@{
    name='tcp_tail'; protocol='tcp'; payload_bytes=128; pipeline_depth=8; sessions=8; threads=2
    cq=4096; memory_bytes=2147483648; socket_buffer_bytes=0; rio_buffer_bytes=65507
    udp_depth=4096; echo_count=17
}
$args = @(New-ClientArguments -Case $tcp -Port 7000)
Assert-True (($args -join '|') -ceq (@('127.0.0.1','/p','tcp','/r','7000','/n','17','/c','8','/threads','2','/k','8','/z','128','/t','120','/cq','4096','/memory','2147483648','/b','0','/q','/stats') -join '|')) 'wrong TCP client arguments'
Assert-True (-not ($args -contains '/w')) 'finite TCP client must not have /w'
$serverArgs = @(New-ServerArguments -Case $tcp -Port 7000)
Assert-True (($serverArgs -contains '/stats') -and -not ($serverArgs -contains '/w')) 'server arguments must include stats and omit /w'

$udp = $tcp.PSObject.Copy()
$udp.protocol='udp'; $udp.payload_bytes=65507; $udp.pipeline_depth=1
$udpArgs = @(New-ClientArguments -Case $udp -Port 7001)
Assert-True (($udpArgs -contains '65507') -and -not ($udpArgs -contains '/k') -and -not ($udpArgs -contains '/w')) 'wrong UDP client arguments'
$bad = $tcp.PSObject.Copy(); $bad.echo_count = 0
$threw = $false
try { $null = New-ClientArguments -Case $bad -Port 7000 } catch { $threw = $true }
Assert-True $threw 'zero echo count accepted'
$bad.echo_count = -1
$threw = $false
try { $null = New-ClientArguments -Case $bad -Port 7000 } catch { $threw = $true }
Assert-True $threw 'negative echo count accepted'

$run = [pscustomobject]@{
    exit_code=0; elapsed_ms=10000; echoed=17; expected_echo_count=17; bytes=2176; expected_bytes=2176
    lost=0; corrupted=0; network_errors=0; server_sha256=('a'*64); expected_server_sha256=('a'*64)
    server_path='C:\bench\server.exe'; expected_server_path='C:\bench\server.exe'; server_pid=123
    server_alive_after_run=$true; stderr_length=0; optimize_mode='ReleaseFast'; reported_elapsed_ms=10000
}
$stop = [pscustomobject]@{ protocol='tcp'; exit_code=0; stderr_length=0; terminal_line='final protocol=tcp active=0'; worker_count=2; zero_workers=2; server_pid=123 }
Assert-True (Test-BenchmarkRun -Run $run -StopRecord $stop) 'valid run and clean stop rejected'
foreach ($mutation in @(
    @{field='exit_code';value=3},@{field='elapsed_ms';value=9999},@{field='echoed';value=16},
    @{field='bytes';value=2175},@{field='lost';value=1},@{field='corrupted';value=1},
    @{field='network_errors';value=1},@{field='server_sha256';value=('b'*64)},
    @{field='server_path';value='C:\bench\other.exe'},@{field='server_alive_after_run';value=$false},
    @{field='stderr_length';value=1},@{field='optimize_mode';value='ReleaseSafe'},
    @{field='reported_elapsed_ms';value=9999}
)) {
    $candidate=$run.PSObject.Copy(); $candidate.($mutation.field)=$mutation.value
    Assert-True (-not (Test-BenchmarkRun -Run $candidate -StopRecord $stop)) "invalid run accepted: $($mutation.field)"
}
$badStop=$stop.PSObject.Copy(); $badStop.terminal_line='final protocol=tcp active=1'
Assert-True (-not (Test-BenchmarkRun -Run $run -StopRecord $badStop)) 'nonterminal TCP stop accepted'
$badStop=$stop.PSObject.Copy(); $badStop.zero_workers=1
Assert-True (-not (Test-BenchmarkRun -Run $run -StopRecord $badStop)) 'active worker accepted'
Assert-True (-not (Test-BenchmarkRun -Run $run -StopRecord $null)) 'absent stop record accepted'
$udpRun=$run.PSObject.Copy(); $udpRun.expected_echo_count=17
$udpStop=[pscustomobject]@{protocol='udp';exit_code=0;stderr_length=0;terminal_line='final protocol=udp outstanding=0';worker_count=0;zero_workers=0;server_pid=123}
Assert-True (Test-BenchmarkRun -Run $udpRun -StopRecord $udpStop) 'clean UDP stop rejected'
$udpStop.terminal_line='final protocol=udp outstanding=1'
Assert-True (-not (Test-BenchmarkRun -Run $udpRun -StopRecord $udpStop)) 'nonterminal UDP stop accepted'

$runner=Join-Path $PSScriptRoot 'perf_loopback.ps1'
Assert-True (Test-Path -LiteralPath $runner -PathType Leaf) 'perf_loopback.ps1 is missing'
$output=Join-Path ([IO.Path]::GetTempPath()) ('zig-server-describe-'+[guid]::NewGuid().ToString('N'))
$manifestCase=@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'perf_workloads.json') -Raw | ConvertFrom-Json | Where-Object { $_.name -ceq 'tcp_128_k1' })[0]
$dryServerArgs=@(New-ServerArguments -Case $manifestCase -Port 7000)
$described=& $runner -ServerPath 'missing-server.exe' -ServerPid 0 -ServerArguments $dryServerArgs `
    -ClientPath 'missing-client.exe' -Port 7000 -Case 'tcp_128_k1' -OutputDirectory $output -Label 'dry-run' -DescribeOnly
Assert-True (($described.client_arguments -contains '/n') -and -not ($described.client_arguments -contains '/w')) 'describe-only client command invalid'
Assert-True (-not (Test-Path -LiteralPath $output)) 'describe-only created output directory'

$totals = Get-WorkloadTotals -Case ([pscustomobject]@{ echo_count = 17; sessions = 8; payload_bytes = 128 })
Assert-True ($totals.echoes -eq 136) 'per-session echo quota was not multiplied by the session count'
Assert-True ($totals.bytes -eq 17408) 'expected bytes ignored the session count'
$single = Get-WorkloadTotals -Case ([pscustomobject]@{ echo_count = 17; sessions = 1; payload_bytes = 128 })
Assert-True ($single.echoes -eq 17 -and $single.bytes -eq 2176) 'single-session totals changed'

# A formal gate must prove the mode, not merely recognise a known one.
$debugRun = $run.PSObject.Copy(); $debugRun.optimize_mode = 'Debug'
Assert-True (-not (Test-BenchmarkRun -Run $debugRun -StopRecord $stop)) 'Debug run satisfied the ReleaseFast gate'
Assert-True (Test-BenchmarkRun -Run $debugRun -StopRecord $stop -RequiredOptimizeMode '') 'unrequired mode rejected'

$modeFixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('perf-mode-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $modeFixtureDirectory
$modeFixtureExe = Join-Path $modeFixtureDirectory 'frozen.exe'
$modeManifest = Join-Path $modeFixtureDirectory 'build-manifest.json'
try {
    Set-Content -LiteralPath $modeFixtureExe -Value 'binary' -Encoding ascii
    $missingModeRejected = $false
    try { $null = Get-ExecutableOptimizeMode -Path $modeFixtureExe } catch { $missingModeRejected = $true }
    Assert-True $missingModeRejected 'missing build manifest was accepted'
    Assert-True ($null -eq (Get-ExecutableOptimizeMode -Path $modeFixtureExe -AllowUnknown)) 'unknown peer mode was invented'

    $fixtureHash = (Get-FileHash -LiteralPath $modeFixtureExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $modeFixtureManifest = [ordered]@{ optimize_mode = 'Debug'; binaries = [ordered]@{ 'frozen.exe' = $fixtureHash } }
    $modeFixtureManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $modeManifest -Encoding utf8
    Assert-True ((Get-ExecutableOptimizeMode -Path $modeFixtureExe) -ceq 'Debug') 'frozen manifest mode was ignored'

    # A binary swapped in after the build must not inherit the manifest's identity.
    Set-Content -LiteralPath $modeFixtureExe -Value 'replaced' -Encoding ascii
    $replacedRejected = $false
    try { $null = Assert-ExecutableIdentity -Path $modeFixtureExe } catch { $replacedRejected = $true }
    Assert-True $replacedRejected 'replaced executable inherited the manifest identity'

    Set-Content -LiteralPath $modeFixtureExe -Value 'binary' -Encoding ascii
    $debugRejected = $false
    try { $null = Assert-ExecutableIdentity -Path $modeFixtureExe -RequiredOptimizeMode 'ReleaseFast' } catch { $debugRejected = $true }
    Assert-True $debugRejected 'Debug executable satisfied a ReleaseFast gate'

    Set-Content -LiteralPath $modeManifest -Value '{"optimize_mode":"ReleaseSafe","binaries":{"frozen.exe":"x"}}' -Encoding ascii
    $unknownModeRejected = $false
    try { $null = Get-ExecutableOptimizeMode -Path $modeFixtureExe } catch { $unknownModeRejected = $true }
    Assert-True $unknownModeRejected 'unknown optimize mode was accepted'
} finally {
    if (Test-Path -LiteralPath $modeManifest) { Remove-Item -LiteralPath $modeManifest }
    if (Test-Path -LiteralPath $modeFixtureExe) { Remove-Item -LiteralPath $modeFixtureExe }
    Remove-Item -LiteralPath $modeFixtureDirectory
}

Write-Output 'server performance runner contract passed'
