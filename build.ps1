param(
    [ValidateSet('Debug', 'ReleaseFast')]
    [string]$Optimize = 'ReleaseFast',

    [string]$ZigPath,

    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
$requiredVersion = '0.17.0-dev.2375+d8aab4878'
$pinnedZig = 'C:\bin\zig-x86_64-windows-0.17.0-dev.2375+d8aab4878\zig.exe'
if (-not $ZigPath) {
    if ($env:ZIG_EXE) {
        $ZigPath = $env:ZIG_EXE
    } elseif (Test-Path -LiteralPath $pinnedZig -PathType Leaf) {
        $ZigPath = $pinnedZig
    } else {
        $fromPath = Get-Command zig -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $ZigPath = if ($fromPath) { $fromPath.Source } else { $pinnedZig }
    }
}

$resolvedZig = (Resolve-Path -LiteralPath $ZigPath -ErrorAction Stop).Path
$actualVersion = (& $resolvedZig version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $requiredVersion) {
    [Console]::Error.WriteLine("zig-echo-server requires Zig $requiredVersion; got '$actualVersion' from '$resolvedZig'.")
    exit 1
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    [Console]::Error.WriteLine("vswhere was not found at '$vswhere'.")
    exit 1
}

$installationPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1).Trim()
if (-not $installationPath) {
    [Console]::Error.WriteLine('No Visual Studio installation with the x64 C++ tools was found.')
    exit 1
}

$vsDevCmd = Join-Path $installationPath 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) {
    [Console]::Error.WriteLine("VsDevCmd.bat was not found at '$vsDevCmd'.")
    exit 1
}

function Invoke-PinnedZig {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $quotedArguments = $Arguments | ForEach-Object {
        if ($_ -match '[\s&|<>^]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    $command = 'call "{0}" -arch=x64 -host_arch=x64 >nul && "{1}" {2}' -f $vsDevCmd, $resolvedZig, ($quotedArguments -join ' ')
    & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Invoke-PinnedZig -Arguments @('build', '-Dtarget=x86_64-windows-msvc', "-Doptimize=$Optimize")
if (-not $BuildOnly) {
    Invoke-PinnedZig -Arguments @('build', 'test', '-Dtarget=x86_64-windows-msvc', "-Doptimize=$Optimize")
}
