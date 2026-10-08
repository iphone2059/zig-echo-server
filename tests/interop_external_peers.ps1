param(
    [Parameter(Mandatory=$true)][string]$ServerPath,
    [Parameter(Mandatory=$true)][string]$ZigClientPath,
    [Parameter(Mandatory=$true)][string]$CppClientPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'interop_child_lifecycle.ps1')
$serverExe=(Resolve-Path -LiteralPath $ServerPath).Path
$peers=@(
    [pscustomobject]@{ name='zig'; path=(Resolve-Path -LiteralPath $ZigClientPath).Path },
    [pscustomobject]@{ name='cpp'; path=(Resolve-Path -LiteralPath $CppClientPath).Path }
)
$cases=@(
    [pscustomobject]@{ name='tcp_batch'; protocol='tcp'; payload=128; count=100000; depth=8 },
    [pscustomobject]@{ name='tcp_tail'; protocol='tcp'; payload=128; count=100003; depth=8 },
    [pscustomobject]@{ name='udp_1200'; protocol='udp'; payload=1200; count=100000; depth=1 },
    [pscustomobject]@{ name='udp_65507'; protocol='udp'; payload=65507; count=10000; depth=1 }
)
$outputRoot=Join-Path (Split-Path -Parent (Split-Path -Parent $serverExe)) 'interop'
$null=New-Item -ItemType Directory -Path $outputRoot -Force
$serverHash=(Get-FileHash -LiteralPath $serverExe -Algorithm SHA256).Hash.ToLowerInvariant()
foreach ($peer in $peers) {
    foreach ($case in $cases) {
        if ($case.protocol -ceq 'tcp') {
            $reservation=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            $reservation.Start()
            try { $port=([Net.IPEndPoint]$reservation.LocalEndpoint).Port }
            finally { $reservation.Stop() }
        } else {
            $reservation=[Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0))
            try { $port=([Net.IPEndPoint]$reservation.Client.LocalEndPoint).Port }
            finally { $reservation.Dispose() }
        }
        $directory=Join-Path $outputRoot ('{0}-{1}-{2}' -f $peer.name,$case.name,[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $directory
        $serverArgs=@('/p',$case.protocol,'/s',[string]$port)
        if ($case.protocol -ceq 'tcp') { $serverArgs+=@('/threads','2') } else { $serverArgs+=@('/k','256') }
        $serverArgs+=@('/rio-buffer','65507','/cq','8192','/memory','134217728','/q','/stats')
        $serverStdout=Join-Path $directory 'server.stdout.txt'
        $serverStderr=Join-Path $directory 'server.stderr.txt'
        $process=Start-Process -FilePath $serverExe -ArgumentList $serverArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
        try {
            Start-Sleep -Milliseconds 400
            if ($process.HasExited) { throw "server exited before $($peer.name)/$($case.name)" }
            $clientArgs=@('127.0.0.1','/p',$case.protocol,'/r',[string]$port,'/n',[string]$case.count,
                '/c','32','/threads','4')
            if ($case.protocol -ceq 'tcp') { $clientArgs+=@('/k',[string]$case.depth) }
            $clientArgs+=@('/z',[string]$case.payload,'/cq','8192','/memory','134217728','/q','/stats')
            $clientStdout=Join-Path $directory 'client.stdout.txt'
            $clientStderr=Join-Path $directory 'client.stderr.txt'
            $client=Start-Process -FilePath $peer.path -ArgumentList $clientArgs -NoNewWindow -PassThru `
                -RedirectStandardOutput $clientStdout -RedirectStandardError $clientStderr
            try {
                Wait-InteropChild -Process $client -TimeoutMilliseconds 60000 -Description "$($peer.name)/$($case.name)"
                if ($client.ExitCode -ne 0) { throw "client exit $($client.ExitCode): $($peer.name)/$($case.name)" }
            } finally { $client.Dispose() }
            $stdout=Get-Content -LiteralPath $clientStdout -Raw
            $stderr=Get-Content -LiteralPath $clientStderr -Raw
            if ($stderr.Length -ne 0) { throw "client stderr: $($peer.name)/$($case.name): $stderr" }
            $final=@($stdout -split "`r?`n" | Where-Object { $_ -match '^final ' } | Select-Object -Last 1)
            if ($final.Count -ne 1) { throw "missing client final: $($peer.name)/$($case.name)" }
            $fields=@{}
            foreach ($matchValue in [regex]::Matches($final[0],'([A-Za-z_]+)=([^\s]+)')) {
                $fields[$matchValue.Groups[1].Value]=$matchValue.Groups[2].Value
            }
            if ([long]$fields.echoed -ne $case.count -or [long]$fields.bytes -ne [long]$case.count*$case.payload -or
                [long]$fields.corrupted -ne 0 -or [long]$fields.lost -ne 0 -or [long]$fields.network_errors -ne 0) {
                throw "client correctness failure: $($peer.name)/$($case.name): $($final[0])"
            }
            $null=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'perf_console_stop.ps1') `
                -ServerPid $process.Id -ServerPath $serverExe -ExpectedServerSha256 $serverHash `
                -Protocol $case.protocol -WorkerCount $(if ($case.protocol -ceq 'tcp') { 2 } else { 0 }) `
                -StdoutPath $serverStdout -StderrPath $serverStderr -OutputDirectory $directory
            if ($LASTEXITCODE -ne 0) { throw "server normal stop failed: $($peer.name)/$($case.name)" }
            Write-Output "interop=PASS peer=$($peer.name) case=$($case.name) echoed=$($case.count) server_sha256=$serverHash"
        } finally {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force
                Write-Warning "interop server force-stopped after incomplete case: $directory"
            }
            $process.Dispose()
        }
    }
}
