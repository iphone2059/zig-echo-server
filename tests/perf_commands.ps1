function Assert-Workload {
    param([Parameter(Mandatory=$true)][pscustomobject]$Case, [Parameter(Mandatory=$true)][int]$Port)
    $required=@('name','protocol','payload_bytes','pipeline_depth','sessions','threads','cq','memory_bytes',
        'socket_buffer_bytes','rio_buffer_bytes','udp_depth','echo_count')
    foreach ($field in $required) { if ($null -eq $Case.PSObject.Properties[$field]) { throw "benchmark case lacks $field" } }
    $protocol=[string]$Case.protocol
    $payload=[long]$Case.payload_bytes
    $pipeline=[long]$Case.pipeline_depth
    $sessions=[long]$Case.sessions
    $threads=[long]$Case.threads
    $cq=[long]$Case.cq
    $memory=[long]$Case.memory_bytes
    $socketBuffer=[long]$Case.socket_buffer_bytes
    $rioBuffer=[long]$Case.rio_buffer_bytes
    $udpDepth=[long]$Case.udp_depth
    $count=[long]$Case.echo_count
    if ($Port -lt 1 -or $Port -gt 65535 -or $protocol -cnotin @('tcp','udp') -or
        $payload -lt 1 -or $payload -gt 65507 -or $pipeline -lt 1 -or
        $sessions -lt 1 -or $sessions -gt 1048576 -or $threads -lt 1 -or $threads -gt 64 -or
        $cq -lt 64 -or $cq -gt 1048576 -or $memory -lt 1048576 -or
        $socketBuffer -lt 0 -or $socketBuffer -gt [int]::MaxValue -or
        $rioBuffer -lt 512 -or $rioBuffer -gt 1048576 -or $udpDepth -lt 1 -or $udpDepth -gt 65536 -or
        $count -lt 1) { throw 'benchmark case has an invalid value' }
    if ($protocol -ceq 'udp' -and ($pipeline -ne 1 -or $rioBuffer -lt 65507)) { throw 'UDP workload has invalid depth or RIO buffer' }
    if ($protocol -ceq 'tcp' -and $payload * $pipeline -gt 67108864) { throw 'TCP batch exceeds 64 MiB' }
    if ($memory -lt 2 * $payload * $pipeline * $sessions) { throw 'registered client memory is too small' }
}

function New-ClientArguments {
    param([Parameter(Mandatory=$true)][pscustomobject]$Case, [Parameter(Mandatory=$true)][int]$Port,
        [string]$HostAddress='127.0.0.1')
    Assert-Workload -Case $Case -Port $Port
    $address=$null
    if (-not [Net.IPAddress]::TryParse($HostAddress,[ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'benchmark peer address must be IPv4' }
    $arguments=@($HostAddress,'/p',[string]$Case.protocol,'/r',[string]$Port,'/n',[string]$Case.echo_count,
        '/c',[string]$Case.sessions,'/threads',[string]$Case.threads)
    if ($Case.protocol -ceq 'tcp') { $arguments+=@('/k',[string]$Case.pipeline_depth) }
    $arguments+=@('/z',[string]$Case.payload_bytes,'/t','30','/cq',[string]$Case.cq,
        '/memory',[string]$Case.memory_bytes,'/b',[string]$Case.socket_buffer_bytes,'/q','/stats')
    return [string[]]$arguments
}

function New-ServerArguments {
    param([Parameter(Mandatory=$true)][pscustomobject]$Case, [Parameter(Mandatory=$true)][int]$Port)
    Assert-Workload -Case $Case -Port $Port
    $arguments=@('/p',[string]$Case.protocol,'/s',[string]$Port)
    if ($Case.protocol -ceq 'tcp') { $arguments+=@('/threads',[string]$Case.threads) }
    else { $arguments+=@('/k',[string]$Case.udp_depth) }
    $arguments+=@('/rio-buffer',[string]$Case.rio_buffer_bytes,'/cq',[string]$Case.cq,
        '/memory',[string]$Case.memory_bytes,'/b',[string]$Case.socket_buffer_bytes,'/q','/stats')
    return [string[]]$arguments
}

function Test-BenchmarkRun {
    param([Parameter(Mandatory=$true)][pscustomobject]$Run, [AllowNull()][pscustomobject]$StopRecord)
    $required=@('exit_code','elapsed_ms','echoed','expected_echo_count','bytes','expected_bytes','lost',
        'corrupted','network_errors','server_sha256','expected_server_sha256','server_path',
        'expected_server_path','server_pid','server_alive_after_run','stderr_length')
    foreach ($field in $required) { if ($null -eq $Run.PSObject.Properties[$field]) { return $false } }
    if ($null -eq $StopRecord) { return $false }
    foreach ($field in @('protocol','exit_code','stderr_length','terminal_line','worker_count','zero_workers','server_pid')) {
        if ($null -eq $StopRecord.PSObject.Properties[$field]) { return $false }
    }
    if ($Run.exit_code -ne 0 -or $Run.elapsed_ms -lt 10000 -or $Run.echoed -ne $Run.expected_echo_count -or
        $Run.bytes -ne $Run.expected_bytes -or $Run.lost -ne 0 -or $Run.corrupted -ne 0 -or
        $Run.network_errors -ne 0 -or $Run.stderr_length -ne 0 -or -not $Run.server_alive_after_run -or
        $StopRecord.exit_code -ne 0 -or $StopRecord.stderr_length -ne 0 -or
        $StopRecord.server_pid -ne $Run.server_pid -or
        -not [string]::Equals($Run.server_sha256,$Run.expected_server_sha256,[StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath($Run.server_path),[IO.Path]::GetFullPath($Run.expected_server_path),[StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($StopRecord.protocol -ceq 'tcp') {
        return $StopRecord.terminal_line -match '^final protocol=tcp\b.*\bactive=0$' -and
            $StopRecord.worker_count -gt 0 -and $StopRecord.worker_count -eq $StopRecord.zero_workers
    }
    if ($StopRecord.protocol -ceq 'udp') {
        return $StopRecord.terminal_line -match '^final protocol=udp\b.*\boutstanding=0$'
    }
    return $false
}

function Get-ExecutableCommit {
    param([Parameter(Mandatory=$true)][string]$Path)
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $marker=Join-Path $directory 'source-commit.txt'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "executable source commit marker missing: $marker" }
    $commit=(Get-Content -LiteralPath $marker -Raw).Trim()
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw "invalid executable source commit marker: $marker" }
    return $commit
}
