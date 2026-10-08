$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'interop_child_lifecycle.ps1')

$child=Start-Process -FilePath (Get-Command pwsh).Source `
    -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') `
    -NoNewWindow -PassThru
$childId=$child.Id
try {
    $timedOut=$false
    try { Wait-InteropChild -Process $child -TimeoutMilliseconds 20 -Description 'contract test' }
    catch {
        if ($_.Exception.Message -match 'timed out') { $timedOut=$true }
        else { throw }
    }
    if (-not $timedOut) { throw 'expected timeout was not reported' }
    if (Get-Process -Id $childId -ErrorAction SilentlyContinue) { throw 'timed-out child remains alive' }
    Write-Output 'interop child timeout cleanup: PASS'
} finally {
    if (Get-Process -Id $childId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    $child.Dispose()
}
