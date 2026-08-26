[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep the compatibility entrypoint under the same comprehensive offline mock
# suite as the canonical Node helper. The suite switches only the generator
# process; discovery and the mock HTTP service remain identical.
$node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$test = Join-Path $PSScriptRoot 'test_node_runtime.js'
$old = [Environment]::GetEnvironmentVariable('KEYLINK_TEST_POWERSHELL', 'Process')
try {
    [Environment]::SetEnvironmentVariable('KEYLINK_TEST_POWERSHELL', '1', 'Process')
    $output = @(& $node.Source $test 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
    $output | Write-Output
}
finally {
    [Environment]::SetEnvironmentVariable('KEYLINK_TEST_POWERSHELL', $old, 'Process')
}
