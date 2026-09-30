param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [Parameter(Mandatory = $true)][string]$CounterPath
)

$deadline = [DateTime]::UtcNow.AddSeconds(10)
$attempts = 0
[IO.File]::WriteAllText($ReadyPath, 'READY')
while ([DateTime]::UtcNow -lt $deadline) {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $tcp.Connect('127.0.0.1', $Port)
        if ($tcp.Connected) { $tcp.GetStream().WriteByte(0x41) }
    } catch [System.Net.Sockets.SocketException] {
    } catch [System.IO.IOException] {
    } finally {
        $tcp.Dispose()
    }
    $attempts++
    if ($attempts % 16 -eq 0) { [IO.File]::WriteAllText($CounterPath, "$attempts") }
    Start-Sleep -Milliseconds 2
}
[IO.File]::WriteAllText($CounterPath, "$attempts")
