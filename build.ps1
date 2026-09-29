param([ValidateSet('Debug','ReleaseSafe','ReleaseFast','ReleaseSmall')][string]$Optimize='ReleaseFast')
$ErrorActionPreference='Stop'
if (-not $env:INCLUDE -or -not $env:LIB) { throw 'Run this script from "x64 Native Tools Command Prompt/Developer PowerShell for VS 2022", so INCLUDE and LIB point at MSVC + Windows SDK.' }
zig version
zig build -Dtarget=x86_64-windows-msvc -Doptimize=$Optimize
