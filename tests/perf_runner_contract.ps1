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
Assert-True (($args -join '|') -ceq (@('127.0.0.1','/p','tcp','/r','7000','/n','17','/c','8','/threads','2','/k','8','/z','128','/t','30','/cq','4096','/memory','2147483648','/b','0','/q','/stats') -join '|')) 'wrong TCP client arguments'
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
    server_alive_after_run=$true; stderr_length=0
}
$stop = [pscustomobject]@{ protocol='tcp'; exit_code=0; stderr_length=0; terminal_line='final protocol=tcp active=0'; worker_count=2; zero_workers=2; server_pid=123 }
Assert-True (Test-BenchmarkRun -Run $run -StopRecord $stop) 'valid run and clean stop rejected'
foreach ($mutation in @(
    @{field='exit_code';value=3},@{field='elapsed_ms';value=9999},@{field='echoed';value=16},
    @{field='bytes';value=2175},@{field='lost';value=1},@{field='corrupted';value=1},
    @{field='network_errors';value=1},@{field='server_sha256';value=('b'*64)},
    @{field='server_path';value='C:\bench\other.exe'},@{field='server_alive_after_run';value=$false},
    @{field='stderr_length';value=1}
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
Write-Output 'server performance runner contract passed'
