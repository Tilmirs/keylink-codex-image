[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Model,

    [ValidateSet('chat', 'images')]
    [string]$EndpointMode,

    [ValidateSet('auto', 'generate', 'edit')]
    [string]$Operation,

    [ValidateSet('auto', 'direct', 'codex')]
    [string]$Route,

    [ValidatePattern('^\d+:\d+$')]
    [string]$AspectRatio,

    [string]$Size,
    [string]$Quality,
    [string]$Background,
    [string]$OutputFormat,

    [ValidateSet('url', 'b64_json')]
    [string]$ResponseFormat,

    [string]$InputImageUrl,
    [string]$InputImagePath,
    [string]$StateFile,
    [string]$ApiKey,
    [string]$ApiKeyFile,
    [string]$BaseUrl,
    [string]$ProxyBaseUrl,
    [string]$Endpoint,
    [string]$OutputPath,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSec = 300,

    [switch]$Overwrite,
    [switch]$UseCodexRoute,
    [switch]$UseCCSwitchCredential,
    [switch]$NoAuth,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The Node helper is the canonical implementation. This Windows entrypoint
# stays thin so endpoint order, multipart upload, response extraction, retries,
# and credential handling cannot drift from the cross-platform implementation.
$node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
$script = Join-Path $PSScriptRoot 'generate_image.js'

$nodeArgs = @($script, '--prompt', $Prompt, '--model', $Model)

function Add-NodeOption {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][bool]$IsBound
    )

    if (-not $IsBound) { return }
    $script:nodeArgs += "--$Name"
    if ($null -ne $Value -and $Value.Length -gt 0) { $script:nodeArgs += $Value }
}

$bound = $PSBoundParameters
Add-NodeOption -Name 'endpoint-mode' -Value $EndpointMode -IsBound $bound.ContainsKey('EndpointMode')
Add-NodeOption -Name 'operation' -Value $Operation -IsBound $bound.ContainsKey('Operation')
if ($UseCodexRoute) {
    $nodeArgs += '--use-codex-route'
}
else {
    Add-NodeOption -Name 'route' -Value $Route -IsBound $bound.ContainsKey('Route')
}
Add-NodeOption -Name 'aspect-ratio' -Value $AspectRatio -IsBound $bound.ContainsKey('AspectRatio')
Add-NodeOption -Name 'size' -Value $Size -IsBound $bound.ContainsKey('Size')
Add-NodeOption -Name 'quality' -Value $Quality -IsBound $bound.ContainsKey('Quality')
Add-NodeOption -Name 'background' -Value $Background -IsBound $bound.ContainsKey('Background')
Add-NodeOption -Name 'output-format' -Value $OutputFormat -IsBound $bound.ContainsKey('OutputFormat')
Add-NodeOption -Name 'response-format' -Value $ResponseFormat -IsBound $bound.ContainsKey('ResponseFormat')
Add-NodeOption -Name 'input-image-url' -Value $InputImageUrl -IsBound $bound.ContainsKey('InputImageUrl')
Add-NodeOption -Name 'input-image-path' -Value $InputImagePath -IsBound $bound.ContainsKey('InputImagePath')
Add-NodeOption -Name 'state-file' -Value $StateFile -IsBound $bound.ContainsKey('StateFile')
Add-NodeOption -Name 'api-key' -Value $ApiKey -IsBound $bound.ContainsKey('ApiKey')
Add-NodeOption -Name 'api-key-file' -Value $ApiKeyFile -IsBound $bound.ContainsKey('ApiKeyFile')
Add-NodeOption -Name 'base-url' -Value $BaseUrl -IsBound $bound.ContainsKey('BaseUrl')
Add-NodeOption -Name 'proxy-base-url' -Value $ProxyBaseUrl -IsBound $bound.ContainsKey('ProxyBaseUrl')
Add-NodeOption -Name 'endpoint' -Value $Endpoint -IsBound $bound.ContainsKey('Endpoint')
Add-NodeOption -Name 'output-path' -Value $OutputPath -IsBound $bound.ContainsKey('OutputPath')

# TimeoutSec has a useful PowerShell default and is therefore always forwarded.
Add-NodeOption -Name 'timeout-sec' -Value ([string]$TimeoutSec) -IsBound $true
if ($Overwrite) { $nodeArgs += '--overwrite' }
if ($UseCCSwitchCredential) { $nodeArgs += '--use-ccswitch-credential' }
if ($NoAuth) { $nodeArgs += '--no-auth' }
if ($DryRun) { $nodeArgs += '--dry-run' }

$output = @(& $node.Source @nodeArgs 2>&1)
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    throw $message
}
$output | Write-Output
