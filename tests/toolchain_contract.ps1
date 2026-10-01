param(
    [Parameter(Mandatory = $true)]
    [string]$ZigPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$requiredVersion = '0.17.0-dev.2320+1e770dbef'

Push-Location $projectRoot
try {
    & (Join-Path $projectRoot 'build.ps1') -Optimize Debug -ZigPath $ZigPath
    if ($LASTEXITCODE -ne 0) {
        throw "Pinned Debug build/test failed with exit code $LASTEXITCODE"
    }

    $installed = Join-Path $projectRoot 'zig-out\bin\zig-echo-server.exe'
    if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
        throw "Expected installed executable was not produced: $installed"
    }

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-echo-server-toolchain-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $savedZigExe = $env:ZIG_EXE
    $savedPath = $env:PATH
    try {
        $fakeZig = Join-Path $fixtureRoot 'zig.cmd'
        Set-Content -LiteralPath $fakeZig -Encoding Ascii -Value "@echo 0.17.0-dev.invalid"
        $output = & pwsh -NoProfile -File (Join-Path $projectRoot 'build.ps1') -Optimize Debug -ZigPath $fakeZig -BuildOnly 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            throw 'A mismatched Zig compiler was accepted.'
        }
        if ($output -notmatch [regex]::Escape($requiredVersion)) {
            throw "Version rejection did not name the required compiler: $output"
        }
        $env:ZIG_EXE = $fakeZig
        $output = & pwsh -NoProfile -File (Join-Path $projectRoot 'build.ps1') -Optimize Debug -BuildOnly 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $output -notmatch [regex]::Escape($requiredVersion)) { throw "ZIG_EXE discovery did not reject a mismatch: $output" }
        $env:ZIG_EXE = $null
        $env:PATH = "$fixtureRoot;$savedPath"
        $output = & pwsh -NoProfile -File (Join-Path $projectRoot 'build.ps1') -Optimize Debug -BuildOnly 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Pinned installation was not preferred over a mismatched PATH compiler: $output" }
    }
    finally {
        $env:ZIG_EXE = $savedZigExe
        $env:PATH = $savedPath
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if ($resolvedFixture.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedFixture) -like 'zig-echo-server-toolchain-*') {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
        } else { throw "Refusing to remove unexpected fixture: $resolvedFixture" }
    }

    Write-Host 'toolchain_contract: PASS'
}
finally {
    Pop-Location
}
