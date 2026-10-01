$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'perf_cpp_reference.ps1'
$description=& $scriptPath -ServerPath 'unused-server.exe' -ClientPath 'unused-client.exe' `
    -Case 'tcp_128_k1' -OutputDirectory 'unused-output' -DescribeOnly
if ($description.reference_only -ne $true -or $description.server_source_commit -ne $null -or
    $description.server_arguments -notcontains '/s' -or $description.client_arguments -notcontains '/n' -or
    $description.client_arguments -notcontains '6400000') {
    throw 'C++ reference must use the frozen workload and disclose unknown source provenance'
}
Write-Output 'C++ reference description contract: PASS'
