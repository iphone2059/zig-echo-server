$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourceDir = Join-Path $root 'src'
# The server is exactly eight source files, mirroring the Rust server's eight modules one for one.
# The list is closed on purpose: adding a file is an architecture change, not a refactor.
$expected = @(
    'contract.zig',
    'engine.zig',
    'internal.zig',
    'main.zig',
    'native.zig',
    'root.zig',
    'server.zig',
    'types.zig'
)
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceDir -Filter '*.zig' -File)
$actual = @($sourceFiles | ForEach-Object { $_.Name } | Sort-Object)
$missing = @($expected | Where-Object { $actual -notcontains $_ })
$extra = @($actual | Where-Object { $expected -notcontains $_ })
if ($missing.Count -ne 0) { throw "server source inventory is missing: $($missing -join ', ')" }
if ($extra.Count -ne 0) { throw "server source inventory has unexpected files: $($extra -join ', ')" }
if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'main.zig'))) { throw 'server entry point must be main.zig' }
$source = ($sourceFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"

$forbidden = @(
    '(?i)\bWSARecv\b',
    '(?i)\bWSASend\b',
    '(?i)\bc\.(recv|send|recvfrom|sendto)\s*\(',
    '(?i)\bextern\s+fn\s+(recv|send|recvfrom|sendto)\b',
    '(?i)\bWSAPoll\b',
    '(?i)\bselect\s*\(',
    '(?i)\bstd\.net\b',
    '(?i)\bstd\.Thread\.Mutex\b',
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
# native.zig may not depend on a state machine: the dependency direction has to stay one-way.
$nativeText = Get-Content -Raw -LiteralPath (Join-Path $sourceDir 'native.zig')
if ($nativeText -match '@import\s*\(\s*"(internal|engine|server|contract)\.zig"\s*\)') {
    throw 'native.zig must not depend on a state machine'
}
Write-Host 'source_policy: PASS'
