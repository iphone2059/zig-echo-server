param(
    [string]$DriverPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\zig-echo-server-sdk-abi-driver.exe')
)

$ErrorActionPreference = 'Stop'
$driver = (Resolve-Path -LiteralPath $DriverPath).Path
$probe = Join-Path $PSScriptRoot 'sdk_abi_probe.cpp'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("zig-echo-server-abi-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $nativeExe = Join-Path $scratch 'sdk_abi_probe.exe'
    $nativeObject = Join-Path $scratch 'sdk_abi_probe.obj'
    $compilerOutput = & cl.exe /nologo /EHsc "/Fe:$nativeExe" "/Fo:$nativeObject" $probe 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Microsoft SDK probe compilation failed: $compilerOutput" }
    $expected = & $nativeExe | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Microsoft SDK probe failed' }
    $actual = & $driver | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Zig SDK declaration probe failed' }
    if ($actual -cne $expected) { throw "Private ABI differs from Microsoft SDK:`nSDK:`n$expected`nZig:`n$actual" }
    Write-Output 'server SDK ABI contract passed'
} finally {
    if (Test-Path -LiteralPath $scratch) {
        $resolvedScratch = (Resolve-Path -LiteralPath $scratch).Path
        if ($resolvedScratch.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedScratch) -like 'zig-echo-server-abi-*') {
            Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
        } else { throw "Refusing to remove unexpected ABI fixture: $resolvedScratch" }
    }
}
