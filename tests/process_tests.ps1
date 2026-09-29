param(
    [string]$ServerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-server.exe'),
    [string]$CppClientPath = (Join-Path $PSScriptRoot '..\..\..\..\cpp-echo-client\build\release\cpp-echo-client.exe')
)

$ErrorActionPreference = 'Stop'
$server = (Resolve-Path -LiteralPath $ServerPath).Path
$client = (Resolve-Path -LiteralPath $CppClientPath).Path
$tcpDriver = Join-Path (Split-Path -Parent $server) 'zig-echo-server-tcp-acceptor-driver.exe'
if (-not (Test-Path -LiteralPath $tcpDriver -PathType Leaf)) { throw "Missing TCP acceptor driver: $tcpDriver" }
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-echo-server-udp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$stdoutPath = Join-Path $scratch 'server.stdout.txt'
$stderrPath = Join-Path $scratch 'server.stderr.txt'
$port = Get-Random -Minimum 20000 -Maximum 50000

try {
    $tcpStdout = Join-Path $scratch 'tcp.stdout.txt'
    $tcpStderr = Join-Path $scratch 'tcp.stderr.txt'
    $tcpPort = Get-Random -Minimum 20000 -Maximum 50000
    $tcpProcess = Start-Process -FilePath $tcpDriver -ArgumentList @($tcpPort, 6, 4, 8192, 1) -PassThru -RedirectStandardOutput $tcpStdout -RedirectStandardError $tcpStderr
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
        $overflow.GetStream().WriteByte(0x41)
        $overflowResult = $overflow.GetStream().ReadByte()
        if ($overflowResult -ne -1) { throw 'TCP worker accepted a connection beyond its two-slot capacity.' }
    }
    catch [System.IO.IOException] { }
    finally { $overflow.Dispose() }

    $first.Dispose()
    Start-Sleep -Milliseconds 150
    $replacement = New-TestTcpClient -Port $tcpPort
    Test-SplitEcho -Tcp $replacement -Payload ([Text.Encoding]::ASCII.GetBytes('free-stack-restored'))
    $replacement.Dispose()

    Start-Sleep -Milliseconds 1200
    try {
        $idleResult = $second.GetStream().ReadByte()
        if ($idleResult -ne -1) { throw 'TCP idle connection remained open beyond /t 1.' }
    }
    catch [System.IO.IOException] { }
    finally { $second.Dispose() }

    $storm = [System.Collections.Generic.List[System.Net.Sockets.TcpClient]]::new()
    for ($index = 0; $index -lt 64; $index++) {
        try { $storm.Add((New-TestTcpClient -Port $tcpPort)) } catch [System.Net.Sockets.SocketException] { }
    }
    foreach ($tcp in $storm) { $tcp.Dispose() }

    if (-not $tcpProcess.WaitForExit(10000)) { throw 'TCP acceptor stop/handoff barrier did not converge.' }
    if ($tcpProcess.ExitCode -ne 0) { throw "TCP acceptor driver failed with exit code $($tcpProcess.ExitCode): $(Get-Content -Raw $tcpStderr)" }
    $tcpError = Get-Content -Raw -LiteralPath $tcpStderr
    $tcpOutput = Get-Content -Raw -LiteralPath $tcpStdout
    if ($tcpError.Length -ne 0) { throw "Successful TCP acceptor driver wrote to stderr: $tcpError" }
    if ($tcpOutput -notmatch '^tcp_driver active=0 failed=false\r?\n?$') { throw "TCP acceptor terminal state mismatch: $tcpOutput" }

    $serverProcess = Start-Process -FilePath $server -ArgumentList @('/p', 'udp', '/s', $port, '/w', '3', '/k', '64', '/cq', '256', '/memory', '67108864', '/q', '/stats') -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Start-Sleep -Milliseconds 350
    if ($serverProcess.HasExited) {
        throw "UDP server exited during startup with code $($serverProcess.ExitCode): $(Get-Content -Raw $stderrPath)"
    }

    & $client 127.0.0.1 /p udp /r $port /n 200 /c 8 /threads 2 /d x /q
    if ($LASTEXITCODE -ne 0) { throw "1-byte UDP echo failed with exit code $LASTEXITCODE" }

    & $client 127.0.0.1 /p udp /r $port /n 32 /c 4 /threads 2 /z 65507 /cq 256 /memory 67108864 /q
    if ($LASTEXITCODE -ne 0) { throw "65507-byte UDP echo failed with exit code $LASTEXITCODE" }

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

    & $client 127.0.0.1 /p udp /r $port /n 100 /c 4 /threads 2 /zt 64 /q
    if ($LASTEXITCODE -ne 0) { throw "UDP echo did not recover after reset probes; exit code $LASTEXITCODE" }

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
    $stopProcess = Start-Process -FilePath $stopDriver -ArgumentList @($stopPort) -PassThru -RedirectStandardOutput $stopStdout -RedirectStandardError $stopStderr
    Start-Sleep -Milliseconds 250
    & $client 127.0.0.1 /p udp /r $stopPort /n 1000000 /c 16 /threads 2 /z 256 /w 1 /q 2>$null
    if (-not $stopProcess.WaitForExit(10000)) { throw 'UDP external stop under load did not converge.' }
    if ($stopProcess.ExitCode -ne 0) { throw "UDP external-stop driver failed with exit code $($stopProcess.ExitCode)." }
    $stopError = Get-Content -Raw -LiteralPath $stopStderr
    $stopOutput = Get-Content -Raw -LiteralPath $stopStdout
    if ($stopError.Length -ne 0) { throw "UDP external-stop path wrote to stderr: $stopError" }
    if ($stopOutput -notmatch $pattern) { throw "UDP external-stop statistics mismatch: $stopOutput" }
    Write-Host 'udp_process_tests: PASS'
}
finally {
    if ($tcpProcess -and -not $tcpProcess.HasExited) { Stop-Process -Id $tcpProcess.Id -Force }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
    if ($stopProcess -and -not $stopProcess.HasExited) { Stop-Process -Id $stopProcess.Id -Force }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
