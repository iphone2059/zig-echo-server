function Wait-InteropChild {
    param(
        [Parameter(Mandatory=$true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory=$true)][string]$Description
    )
    $completed=$false
    try {
        $completed=$Process.WaitForExit($TimeoutMilliseconds)
    } finally {
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction Stop
            if (-not $Process.WaitForExit(30000)) {
                throw "client did not terminate after forced stop: $Description"
            }
        }
    }
    if (-not $completed) { throw "client timed out: $Description" }
}
