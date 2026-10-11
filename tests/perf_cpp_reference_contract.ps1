$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'perf_cpp_reference.ps1'
$description=& $scriptPath -ServerPath 'unused-server.exe' -ClientPath 'unused-client.exe' `
    -Case 'tcp_128_k1' -OutputDirectory 'unused-output' -DescribeOnly
$frozen = @(@(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'perf_workloads.json') -Raw | ConvertFrom-Json) |
    Where-Object { $_.name -ceq 'tcp_128_k1' })[0]
# The reference must be driven by the frozen manifest rather than by a literal that goes stale the
# next time the workload is recalibrated.
if ($description.reference_only -ne $true -or $description.server_source_commit -ne $null -or
    $description.server_arguments -notcontains '/s' -or $description.client_arguments -notcontains '/n' -or
    $description.client_arguments -notcontains ([string]$frozen.echo_count)) {
    throw 'C++ reference must use the frozen workload and disclose unknown source provenance'
}
Write-Output 'C++ reference description contract: PASS'
