param(
    [string]$ServerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-server.exe'),
    [string]$CppClientPath
)

$ErrorActionPreference = 'Stop'
$server = (Resolve-Path -LiteralPath $ServerPath).Path
$client = if ($CppClientPath) { (Resolve-Path -LiteralPath $CppClientPath).Path } else { $null }

function Test-TcpEcho([int]$Port, [byte[]]$Payload, [int]$Count) {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $tcp.ReceiveTimeout = 3000
        $tcp.SendTimeout = 3000
        $tcp.Connect('127.0.0.1', $Port)
        $stream = $tcp.GetStream()
        $received = [byte[]]::new($Payload.Length)
        for ($attempt = 0; $attempt -lt $Count; $attempt++) {
            $stream.Write($Payload, 0, $Payload.Length)
            $offset = 0
            while ($offset -lt $received.Length) {
                $read = $stream.Read($received, $offset, $received.Length - $offset)
                if ($read -eq 0) { throw "TCP EOF after $offset bytes" }
                $offset += $read
            }
            if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($Payload, $received)) { throw 'TCP echo payload mismatch' }
        }
    } finally { $tcp.Dispose() }
}

function Test-UdpEcho([int]$Port, [byte[]]$Payload, [int]$Count) {
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = 3000
        $udp.Connect('127.0.0.1', $Port)
        for ($attempt = 0; $attempt -lt $Count; $attempt++) {
            [void]$udp.Send($Payload, $Payload.Length)
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $received = $udp.Receive([ref]$remote)
            if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($Payload, $received)) { throw 'UDP echo payload mismatch' }
        }
    } finally { $udp.Dispose() }
}

function Test-TcpClosed([System.Net.Sockets.TcpClient]$Tcp, [string]$Stage) {
    try {
        if ($Tcp.GetStream().ReadByte() -ne -1) { throw "$Stage remained open" }
    } catch [System.IO.IOException] {
        $socketError = $_.Exception.InnerException
        if ($socketError -is [System.Net.Sockets.SocketException] -and $socketError.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
            throw "$Stage timed out instead of closing"
        }
    }
}
$tcpDriver = Join-Path (Split-Path -Parent $server) 'zig-echo-server-tcp-acceptor-driver.exe'
if (-not (Test-Path -LiteralPath $tcpDriver -PathType Leaf)) { throw "Missing TCP acceptor driver: $tcpDriver" }
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-echo-server-udp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$stdoutPath = Join-Path $scratch 'server.stdout.txt'
$stderrPath = Join-Path $scratch 'server.stderr.txt'
$port = Get-Random -Minimum 20000 -Maximum 50000

try {
    $serverTcpStdout = Join-Path $scratch 'server-tcp.stdout.txt'
    $serverTcpStderr = Join-Path $scratch 'server-tcp.stderr.txt'
    $serverTcpPort = Get-Random -Minimum 20000 -Maximum 50000
    $serverTcpProcess = Start-Process -FilePath $server -ArgumentList @('/p', 'tcp', '/s', $serverTcpPort, '/threads', '2', '/t', '1', '/w', '3', '/rio-buffer', '4096', '/cq', '256', '/memory', '67108864', '/q', '/stats') -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverTcpStdout -RedirectStandardError $serverTcpStderr
    Start-Sleep -Milliseconds 400
    if ($serverTcpProcess.HasExited) { throw "TCP server exited during startup with code $($serverTcpProcess.ExitCode): $(Get-Content -Raw $serverTcpStderr)" }
    if ($client) {
        & $client 127.0.0.1 /p tcp /r $serverTcpPort /n 1000 /c 16 /threads 2 /k 4 /zt 64 /q
        if ($LASTEXITCODE -ne 0) { throw "TCP C++ client acceptance failed with exit code $LASTEXITCODE" }
    } else {
        Test-TcpEcho -Port $serverTcpPort -Payload ([Text.Encoding]::ASCII.GetBytes('self-contained TCP RIO echo')) -Count 64
    }
    if (-not $serverTcpProcess.WaitForExit(10000)) { throw 'TCP server run-duration shutdown did not converge.' }
    if ($serverTcpProcess.ExitCode -ne 0) { throw "TCP server failed with exit code $($serverTcpProcess.ExitCode)." }
    $serverTcpError = Get-Content -Raw -LiteralPath $serverTcpStderr
    $serverTcpOutput = Get-Content -Raw -LiteralPath $serverTcpStdout
    if ($serverTcpError.Length -ne 0) { throw "Successful TCP server wrote to stderr: $serverTcpError" }
    $workerLines = [regex]::Matches($serverTcpOutput, '(?m)^\[worker \d+\] accepted=\d+ completions=\d+ receives=\d+ sends=\d+ bytes=\d+ active=0\r?$')
    if ($workerLines.Count -ne 2) { throw "Expected two exact per-worker statistics lines: $serverTcpOutput" }
    if ($serverTcpOutput -notmatch '(?m)^final protocol=tcp elapsed_ms=\d+ accepted=\d+ completions=\d+ receives=\d+ sends=\d+ bytes=\d+ MiB_per_sec=\d+\.\d{2} active=0\r?$') {
        throw "TCP aggregate statistics schema mismatch: $serverTcpOutput"
    }

    $tcpStdout = Join-Path $scratch 'tcp.stdout.txt'
    $tcpStderr = Join-Path $scratch 'tcp.stderr.txt'
    $tcpPort = Get-Random -Minimum 20000 -Maximum 50000
    $tcpProcess = Start-Process -FilePath $tcpDriver -ArgumentList @($tcpPort, 6, 4, 8192, 1) -WindowStyle Hidden -PassThru -RedirectStandardOutput $tcpStdout -RedirectStandardError $tcpStderr
    Start-Sleep -Milliseconds 400
    if ($tcpProcess.HasExited) { throw "TCP acceptor driver exited during startup: $(Get-Content -Raw $tcpStderr)" }

    function New-TestTcpClient {
        param([int]$Port)
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = 2000
        $tcp.SendTimeout = 2000
        $tcp.Connect('127.0.0.1', $Port)
        return $tcp
    }
    function Test-SplitEcho {
        param([System.Net.Sockets.TcpClient]$Tcp, [byte[]]$Payload)
        $stream = $Tcp.GetStream()
        $split = [Math]::Max(1, [int]($Payload.Length / 3))
        $stream.Write($Payload, 0, $split)
        Start-Sleep -Milliseconds 10
        $stream.Write($Payload, $split, $Payload.Length - $split)
        $received = [byte[]]::new($Payload.Length)
        $offset = 0
        while ($offset -lt $received.Length) {
            $count = $stream.Read($received, $offset, $received.Length - $offset)
            if ($count -eq 0) { throw "TCP EOF after $offset of $($received.Length) bytes" }
            $offset += $count
        }
        if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($Payload, $received)) { throw 'TCP split echo payload mismatch.' }
    }

    $first = New-TestTcpClient -Port $tcpPort
    $second = New-TestTcpClient -Port $tcpPort
    Test-SplitEcho -Tcp $first -Payload ([Text.Encoding]::ASCII.GetBytes('split-write-and-read-one'))
    Test-SplitEcho -Tcp $second -Payload ([byte[]](1..255))

    $overflow = New-TestTcpClient -Port $tcpPort
    try {
        $wrote = $false
        try {
            $overflow.GetStream().WriteByte(0x41)
            $wrote = $true
        } catch [System.IO.IOException] {
            $socketError = $_.Exception.InnerException
            if ($socketError -is [System.Net.Sockets.SocketException] -and $socketError.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) { throw }
        }
        if ($wrote) { Test-TcpClosed -Tcp $overflow -Stage 'TCP overflow connection' }
    }
    finally { $overflow.Dispose() }

    $first.Dispose()
    Start-Sleep -Milliseconds 150
    $replacement = New-TestTcpClient -Port $tcpPort
    Test-SplitEcho -Tcp $replacement -Payload ([Text.Encoding]::ASCII.GetBytes('free-stack-restored'))
    $replacement.Dispose()

    Start-Sleep -Milliseconds 1200
    try { Test-TcpClosed -Tcp $second -Stage 'TCP idle connection' }
    finally { $second.Dispose() }

    $stormReady = Join-Path $scratch 'storm.ready.txt'
    $stormCount = Join-Path $scratch 'storm.count.txt'
    $stormScript = Join-Path $PSScriptRoot 'tcp_storm.ps1'
    $stormProcess = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', "`"$stormScript`"", '-Port', "$tcpPort", '-ReadyPath', "`"$stormReady`"", '-CounterPath', "`"$stormCount`"") -WindowStyle Hidden -PassThru
    $stormReadyUntil = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $stormReady) -and [DateTime]::UtcNow -lt $stormReadyUntil) { Start-Sleep -Milliseconds 20 }
    if (-not (Test-Path -LiteralPath $stormReady)) { throw 'TCP shutdown storm did not start' }

    if (-not $tcpProcess.WaitForExit(10000)) { throw 'TCP acceptor stop/handoff barrier did not converge.' }
    if ($stormProcess.HasExited) { throw 'TCP storm ended before the acceptor shutdown boundary.' }
    $stormAttempts = if (Test-Path -LiteralPath $stormCount) { [int](Get-Content -LiteralPath $stormCount -Raw) } else { 0 }
    if ($stormAttempts -lt 16) { throw "TCP storm did not generate enough connection attempts: $stormAttempts" }
    if ($tcpProcess.ExitCode -ne 0) { throw "TCP acceptor driver failed with exit code $($tcpProcess.ExitCode): $(Get-Content -Raw $tcpStderr)" }
    $tcpError = Get-Content -Raw -LiteralPath $tcpStderr
    $tcpOutput = Get-Content -Raw -LiteralPath $tcpStdout
    if ($tcpError.Length -ne 0) { throw "Successful TCP acceptor driver wrote to stderr: $tcpError" }
    if ($tcpOutput -notmatch '^tcp_driver active=0 failed=false\r?\n?$') { throw "TCP acceptor terminal state mismatch: $tcpOutput" }

    $serverProcess = Start-Process -FilePath $server -ArgumentList @('/p', 'udp', '/s', $port, '/w', '3', '/k', '64', '/cq', '256', '/memory', '67108864', '/q', '/stats') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Start-Sleep -Milliseconds 350
    if ($serverProcess.HasExited) {
        throw "UDP server exited during startup with code $($serverProcess.ExitCode): $(Get-Content -Raw $stderrPath)"
    }

    if ($client) {
        & $client 127.0.0.1 /p udp /r $port /n 200 /c 8 /threads 2 /d x /q
        if ($LASTEXITCODE -ne 0) { throw "1-byte UDP echo failed with exit code $LASTEXITCODE" }
        & $client 127.0.0.1 /p udp /r $port /n 32 /c 4 /threads 2 /z 65507 /cq 256 /memory 67108864 /q
        if ($LASTEXITCODE -ne 0) { throw "65507-byte UDP echo failed with exit code $LASTEXITCODE" }
    } else {
        Test-UdpEcho -Port $port -Payload ([byte[]](0x78)) -Count 200
        $largest = [byte[]]::new(65507)
        for ($index = 0; $index -lt $largest.Length; $index++) { $largest[$index] = [byte]($index % 256) }
        Test-UdpEcho -Port $port -Payload $largest -Count 32
    }

    for ($index = 0; $index -lt 32; $index++) {
        $probe = [System.Net.Sockets.UdpClient]::new()
        try {
            $probe.Connect('127.0.0.1', $port)
            [void]$probe.Send([byte[]](0x5a), 1)
        }
        finally {
            $probe.Dispose()
        }
    }

    if ($client) {
        & $client 127.0.0.1 /p udp /r $port /n 100 /c 4 /threads 2 /zt 64 /q
        if ($LASTEXITCODE -ne 0) { throw "UDP echo did not recover after reset probes; exit code $LASTEXITCODE" }
    } else {
        Test-UdpEcho -Port $port -Payload ([Text.Encoding]::ASCII.GetBytes('00000000 00000001 ')) -Count 100
    }

    if (-not $serverProcess.WaitForExit(10000)) {
        throw 'UDP run-duration stop did not converge within 10 seconds.'
    }
    if ($serverProcess.ExitCode -ne 0) {
        throw "UDP server failed with exit code $($serverProcess.ExitCode)."
    }

    $stdout = Get-Content -Raw -LiteralPath $stdoutPath
    $stderr = Get-Content -Raw -LiteralPath $stderrPath
    if ($stderr.Length -ne 0) { throw "Successful UDP server wrote to stderr: $stderr" }
    $pattern = '^final protocol=udp elapsed_ms=\d+ completions=\d+ receives=\d+ sends=\d+ bytes=\d+ MiB_per_sec=\d+\.\d{2} outstanding=0\r?\n?$'
    if ($stdout -notmatch $pattern) { throw "UDP statistics schema/stdout mismatch: $stdout" }

    $stopDriver = Join-Path (Split-Path -Parent $server) 'zig-echo-server-udp-stop-driver.exe'
    if (-not (Test-Path -LiteralPath $stopDriver -PathType Leaf)) { throw "Missing UDP external-stop driver: $stopDriver" }
    $stopStdout = Join-Path $scratch 'stop.stdout.txt'
    $stopStderr = Join-Path $scratch 'stop.stderr.txt'
    $stopPort = Get-Random -Minimum 20000 -Maximum 50000
    $stopProcess = Start-Process -FilePath $stopDriver -ArgumentList @($stopPort) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stopStdout -RedirectStandardError $stopStderr
    Start-Sleep -Milliseconds 250
    if ($client) {
        & $client 127.0.0.1 /p udp /r $stopPort /n 1000000 /c 16 /threads 2 /z 256 /w 1 /q 2>$null
    } else {
        $load = [System.Net.Sockets.UdpClient]::new()
        try {
            $load.Client.ReceiveTimeout = 100
            $load.Connect('127.0.0.1', $stopPort)
            $payload = [byte[]]::new(256)
            $deadline = [DateTime]::UtcNow.AddMilliseconds(1200)
            while ([DateTime]::UtcNow -lt $deadline) {
                try {
                    [void]$load.Send($payload, $payload.Length)
                    $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                    [void]$load.Receive([ref]$remote)
                } catch [System.Net.Sockets.SocketException] { }
            }
        } finally { $load.Dispose() }
    }
    if (-not $stopProcess.WaitForExit(10000)) { throw 'UDP external stop under load did not converge.' }
    $stopError = Get-Content -Raw -LiteralPath $stopStderr
    $stopOutput = Get-Content -Raw -LiteralPath $stopStdout
    if ($stopProcess.ExitCode -ne 0) { throw "UDP external-stop driver failed with exit code $($stopProcess.ExitCode). stdout: $stopOutput stderr: $stopError" }
    if ($stopError.Length -ne 0) { throw "UDP external-stop path wrote to stderr: $stopError" }
    if ($stopOutput -notmatch $pattern) { throw "UDP external-stop statistics mismatch: $stopOutput" }
    Write-Host 'udp_process_tests: PASS'
}
finally {
    if ($stormProcess -and -not $stormProcess.HasExited) { Stop-Process -Id $stormProcess.Id -Force }
    if ($serverTcpProcess -and -not $serverTcpProcess.HasExited) { Stop-Process -Id $serverTcpProcess.Id -Force }
    if ($tcpProcess -and -not $tcpProcess.HasExited) { Stop-Process -Id $tcpProcess.Id -Force }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
    if ($stopProcess -and -not $stopProcess.HasExited) { Stop-Process -Id $stopProcess.Id -Force }
    if (Test-Path -LiteralPath $scratch) {
        $resolvedScratch = (Resolve-Path -LiteralPath $scratch).Path
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedScratch.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedScratch) -notlike 'zig-echo-server-udp-*') {
            throw "Refusing to remove unexpected test directory: $resolvedScratch"
        }
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
