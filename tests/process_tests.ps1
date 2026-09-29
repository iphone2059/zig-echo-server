param(
    [string]$ServerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-server.exe'),
    [string]$CppClientPath = (Join-Path $PSScriptRoot '..\..\..\..\cpp-echo-client\build\release\cpp-echo-client.exe')
)

$ErrorActionPreference = 'Stop'
$server = (Resolve-Path -LiteralPath $ServerPath).Path
$client = (Resolve-Path -LiteralPath $CppClientPath).Path
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-echo-server-udp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$stdoutPath = Join-Path $scratch 'server.stdout.txt'
$stderrPath = Join-Path $scratch 'server.stderr.txt'
$port = Get-Random -Minimum 20000 -Maximum 50000

try {
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
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
    if ($stopProcess -and -not $stopProcess.HasExited) { Stop-Process -Id $stopProcess.Id -Force }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
