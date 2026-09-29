$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourceFiles = Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.zig' -File
$source = ($sourceFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"

$forbidden = @(
    '(?i)\bWSARecv\b',
    '(?i)\bWSASend\b',
    '(?i)\bc\.(recv|send|recvfrom|sendto)\s*\(',
    '(?i)\bextern\s+fn\s+(recv|send|recvfrom|sendto)\b',
    '(?i)\bWSAPoll\b',
    '(?i)\bselect\s*\(',
    '(?i)\bstd\.net\b',
    '(?i)cpp-echo-(client|server)',
    '(?i)dotnet-echo-(client|server)',
    '(?i)zig-echo-client',
    '(?i)\.\.\\.*echo-'
)
foreach ($pattern in $forbidden) {
    if ($source -match $pattern) { throw "Forbidden fallback or cross-project source pattern: $pattern" }
}
foreach ($required in @('RIOReceive', 'RIOSend', 'RIODequeueCompletion', 'RIONotify', 'GetQueuedCompletionStatus', 'AcceptEx')) {
    if ($source -notmatch [regex]::Escape($required)) { throw "Required native architecture token is absent: $required" }
}
Write-Host 'source_policy: PASS'
