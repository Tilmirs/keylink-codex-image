[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$ApiKeyFile,
    [string]$BaseUrl,
    [string]$ProxyBaseUrl,
    [string]$Endpoint,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSec = 60,

    [switch]$UseCCSwitchCredential,
    [switch]$UseCodexRoute,
    [switch]$NoAuth,
    [switch]$IncludeAllModels,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FirstNonEmptyValue {
    param([object[]]$Values)

    foreach ($value in $Values) {
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return ([string]$value).Trim()
        }
    }
    return $null
}

function Get-EnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    return Get-FirstNonEmptyValue @(
        [Environment]::GetEnvironmentVariable($Name, 'Process'),
        [Environment]::GetEnvironmentVariable($Name, 'User'),
        [Environment]::GetEnvironmentVariable($Name, 'Machine')
    )
}

function Test-IsLoopbackUrl {
    param([Parameter(Mandatory)][string]$Url)
    try { return ([Uri]$Url).Host -in @('127.0.0.1', 'localhost', '::1') }
    catch { return $false }
}

function Get-ObjectProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-KeylinkApiKeyFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "API key file does not exist: $resolvedPath"
    }
    $fileKey = Get-Content -LiteralPath $resolvedPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    $fileKey = Get-FirstNonEmptyValue @($fileKey)
    if (-not $fileKey) { throw "API key file is empty: $resolvedPath" }
    return $fileKey
}

function Get-CCSwitchDatabasePath {
    $configuredPath = Get-EnvironmentValue 'CCSWITCH_DB_PATH'
    if ($configuredPath) {
        $resolvedPath = [IO.Path]::GetFullPath($configuredPath)
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw "CCSwitch database does not exist: $resolvedPath"
        }
        return $resolvedPath
    }

    $candidates = @(
        (Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'),
        (Join-Path (Get-FirstNonEmptyValue @((Get-EnvironmentValue 'APPDATA'), $env:APPDATA)) 'com.ccswitch.desktop\cc-switch.db'),
        (Join-Path (Get-FirstNonEmptyValue @((Get-EnvironmentValue 'LOCALAPPDATA'), $env:LOCALAPPDATA)) 'com.ccswitch.desktop\cc-switch.db')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'CCSwitch database was not found. Set CCSWITCH_DB_PATH or install CCSwitch for the current user.'
}

function Get-CodexRouteBaseUrl {
    param([string]$ConfiguredProxyBaseUrl)

    $proxyOverride = Get-FirstNonEmptyValue @(
        $ConfiguredProxyBaseUrl,
        (Get-EnvironmentValue 'KEYLINK_PROXY_BASE_URL')
    )
    if ($proxyOverride) { return $proxyOverride }

    $codexRoot = Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'CODEX_HOME'),
        (Join-Path $env:USERPROFILE '.codex')
    )
    $configPath = Join-Path $codexRoot 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Codex config does not exist: $configPath"
    }
    $providerName = $null
    foreach ($line in [IO.File]::ReadLines($configPath)) {
        if ($line -match '^\s*model_provider\s*=\s*["''](?<name>[^"'']+)["'']') {
            $providerName = $Matches['name']
            break
        }
    }
    if (-not $providerName) { throw "Codex config does not declare model_provider: $configPath" }

    $inProviderSection = $false
    $sectionPattern = '^\s*\[model_providers\.' + [regex]::Escape($providerName) + '\]\s*$'
    foreach ($line in [IO.File]::ReadLines($configPath)) {
        if ($line -match '^\s*\[') {
            $inProviderSection = $line -match $sectionPattern
            continue
        }
        if ($inProviderSection -and $line -match '^\s*base_url\s*=\s*["''](?<url>[^"'']+)["'']') {
            return $Matches['url']
        }
    }
    throw "Codex provider '$providerName' does not declare base_url in $configPath"
}

function Resolve-CCSwitchApiKey {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) {
        throw 'Reading the CCSwitch credential requires Node.js 22 or newer with node:sqlite support.'
    }

    $helperPath = Join-Path $PSScriptRoot 'read_ccswitch_credential.js'
    $encodedOutput = @(& $node.Source $helperPath (Get-CCSwitchDatabasePath) 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $safeError = Get-FirstNonEmptyValue @(($encodedOutput | ForEach-Object { [string]$_ }) -join ' ')
        throw "CCSwitch credential lookup failed: $safeError"
    }

    try {
        $encodedKey = Get-FirstNonEmptyValue @($encodedOutput | Select-Object -Last 1)
        $decodedKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedKey))
    }
    catch {
        throw 'CCSwitch credential lookup returned an invalid credential.'
    }
    if ([string]::IsNullOrWhiteSpace($decodedKey)) {
        throw 'The current CCSwitch Codex provider has no API key.'
    }
    return $decodedKey.Trim()
}

function Resolve-KeylinkApiKey {
    $explicitKey = Get-FirstNonEmptyValue @($ApiKey)
    if ($explicitKey) { return $explicitKey }
    if ($ApiKeyFile) { return Read-KeylinkApiKeyFile $ApiKeyFile }
    if ($UseCCSwitchCredential) { return Resolve-CCSwitchApiKey }

    $environmentKey = Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'KEYLINK_IMAGE_API_KEY'),
        (Get-EnvironmentValue 'KEYLINK_API_KEY')
    )
    if ($environmentKey) { return $environmentKey }

    $environmentKeyFile = Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'KEYLINK_IMAGE_API_KEY_FILE'),
        (Get-EnvironmentValue 'KEYLINK_API_KEY_FILE')
    )
    if ($environmentKeyFile) { return Read-KeylinkApiKeyFile $environmentKeyFile }

    $codexRoot = Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'CODEX_HOME'),
        (Join-Path $env:USERPROFILE '.codex')
    )
    $defaultKeyFile = Join-Path $codexRoot 'secrets\keylink-image-api-key.txt'
    if (Test-Path -LiteralPath $defaultKeyFile -PathType Leaf) {
        return Read-KeylinkApiKeyFile $defaultKeyFile
    }
    throw 'Listing Keylink models requires an API key source.'
}

function Resolve-ModelsEndpoint {
    if ($Endpoint) { return $Endpoint.Trim() }
    $configuredProxyBaseUrl = Get-FirstNonEmptyValue @(
        $ProxyBaseUrl,
        (Get-EnvironmentValue 'KEYLINK_PROXY_BASE_URL')
    )
    $base = if ($UseCodexRoute -or $configuredProxyBaseUrl) {
        Get-CodexRouteBaseUrl $configuredProxyBaseUrl
    }
    else {
        Get-FirstNonEmptyValue @(
            $BaseUrl,
            (Get-EnvironmentValue 'KEYLINK_IMAGE_BASE_URL'),
            (Get-EnvironmentValue 'KEYLINK_BASE_URL'),
            'https://keylinkclub.com'
        )
    }
    $base = $base.TrimEnd('/')
    if ($base -match '/v1$') { return "$base/models" }
    return "$base/v1/models"
}

function Get-ImageModelEvidence {
    param(
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][string]$ModelJson
    )

    $knownModels = @(
        'gpt-image-2',
        'gemini-3-pro-image',
        'gemini-2.5-flash-image',
        'gemini-3.1-flash-image'
    )
    if (@($knownModels | Where-Object { $_ -ieq $ModelId }).Count -gt 0) {
        return 'known-model-id'
    }
    if ($ModelJson -match '(?i)image[_-]?generation\s*"?\s*:\s*true' -or
        $ModelJson -match '(?i)(output[_-]?modalities|modalities)[^\]}]*image') {
        return 'api-capability-metadata'
    }
    if ($ModelId -match '(?i)(^|[-_.])(image|imagen|flux|dall[-_.]?e)([-_.]|$)') {
        return 'model-id-pattern'
    }
    return $null
}

function Get-ResolutionMetadata {
    param([Parameter(Mandatory)][object]$Model)

    $modelJson = $Model | ConvertTo-Json -Depth 30 -Compress
    $sizes = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($modelJson, '(?<!\d)(?<size>\d{2,5}\s*[xX]\s*\d{2,5})(?!\d)')) {
        [void]$sizes.Add($match.Groups['size'].Value.Replace(' ', '').ToLowerInvariant())
    }

    function Add-NestedResolutions {
        param([object]$Value)
        if ($null -eq $Value) { return }
        if ($Value -is [System.Collections.IDictionary]) {
            $width = $Value['width']
            $height = $Value['height']
            $parsedWidth = 0
            $parsedHeight = 0
            if ([int]::TryParse([string]$width, [ref]$parsedWidth) -and
                [int]::TryParse([string]$height, [ref]$parsedHeight)) {
                [void]$sizes.Add("${parsedWidth}x${parsedHeight}")
            }
            foreach ($item in $Value.Values) { Add-NestedResolutions $item }
            return
        }
        if ($Value -is [pscustomobject]) {
            $width = Get-ObjectProperty $Value 'width'
            $height = Get-ObjectProperty $Value 'height'
            $parsedWidth = 0
            $parsedHeight = 0
            if ([int]::TryParse([string]$width, [ref]$parsedWidth) -and
                [int]::TryParse([string]$height, [ref]$parsedHeight)) {
                [void]$sizes.Add("${parsedWidth}x${parsedHeight}")
            }
            foreach ($property in $Value.PSObject.Properties) { Add-NestedResolutions $property.Value }
            return
        }
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            foreach ($item in $Value) { Add-NestedResolutions $item }
        }
    }

    Add-NestedResolutions $Model
    $sizes = @($sizes | Sort-Object -Unique)

    $aspectRatios = @([regex]::Matches($modelJson, '(?<!\d)(?<ratio>\d{1,2}:\d{1,2})(?!\d)') |
        ForEach-Object { $_.Groups['ratio'].Value } | Sort-Object -Unique)

    return [pscustomobject]@{
        AdvertisedSizes = $sizes
        AdvertisedAspectRatios = $aspectRatios
    }
}

if ($UseCodexRoute -and $BaseUrl) { throw 'Specify either -UseCodexRoute or -BaseUrl, not both.' }
if ($UseCodexRoute -and $UseCCSwitchCredential) { throw 'Do not combine -UseCodexRoute with -UseCCSwitchCredential.' }
if ($NoAuth -and ($ApiKey -or $ApiKeyFile -or $UseCCSwitchCredential)) { throw 'Do not combine -NoAuth with an API key source.' }
if ($ProxyBaseUrl -and $BaseUrl) { throw 'Specify either -ProxyBaseUrl or -BaseUrl, not both.' }

$resolvedEndpoint = Resolve-ModelsEndpoint
if ($UseCCSwitchCredential) {
    $hostName = ([Uri]$resolvedEndpoint).Host.ToLowerInvariant()
    if ($hostName -ne 'keylinkclub.com' -and -not $hostName.EndsWith('.keylinkclub.com')) {
        throw 'The CCSwitch credential can only be sent to keylinkclub.com.'
    }
}

if ($DryRun) {
    [pscustomobject]@{
        Endpoint = $resolvedEndpoint
        CredentialSource = if ($UseCCSwitchCredential) { 'ccswitch-current-codex-provider' } elseif ($ApiKey) { 'explicit-key' } elseif ($ApiKeyFile) { 'explicit-key-file' } else { 'environment-or-default-key-file' }
    } | ConvertTo-Json -Depth 5
    return
}

$effectiveNoAuth = $NoAuth -or ($UseCodexRoute -and (Test-IsLoopbackUrl $resolvedEndpoint))
$apiKey = if ($effectiveNoAuth) { $null } else { Resolve-KeylinkApiKey }
$headers = @{}
if ($apiKey) { $headers.Authorization = "Bearer $apiKey" }
try {
    $response = Invoke-RestMethod -Uri $resolvedEndpoint -Method Get -Headers $headers -TimeoutSec $TimeoutSec
}
catch {
    $details = Get-FirstNonEmptyValue @(
        (Get-ObjectProperty (Get-ObjectProperty $_ 'ErrorDetails') 'Message'),
        (Get-ObjectProperty (Get-ObjectProperty $_ 'Exception') 'Message'),
        [string]$_
    )
    if ($apiKey) { $details = $details.Replace($apiKey, '<redacted>') }
    throw "Keylink model discovery failed: $details"
}

$rawModels = Get-ObjectProperty $response 'data'
if ($null -eq $rawModels) { $rawModels = Get-ObjectProperty $response 'models' }
if ($null -eq $rawModels -and $response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
    $rawModels = $response
}
if ($null -eq $rawModels) { throw 'The models response did not contain data or models.' }

$models = @()
foreach ($rawModel in @($rawModels)) {
    $modelId = if ($rawModel -is [string]) {
        [string]$rawModel
    }
    else {
        Get-FirstNonEmptyValue @(
            (Get-ObjectProperty $rawModel 'id'),
            (Get-ObjectProperty $rawModel 'model'),
            (Get-ObjectProperty $rawModel 'name')
        )
    }
    if (-not $modelId) { continue }

    $modelJson = $rawModel | ConvertTo-Json -Depth 30 -Compress
    $evidence = Get-ImageModelEvidence -ModelId $modelId -ModelJson $modelJson
    if (-not $IncludeAllModels -and -not $evidence) { continue }

    $resolution = Get-ResolutionMetadata $rawModel
    $displayName = if ($rawModel -is [string]) { $modelId } else {
        Get-FirstNonEmptyValue @(
            (Get-ObjectProperty $rawModel 'display_name'),
            (Get-ObjectProperty $rawModel 'name'),
            $modelId
        )
    }
    $models += [pscustomobject]@{
        Id = $modelId
        DisplayName = $displayName
        ImageCapable = [bool]$evidence
        ImageCapabilityEvidence = $evidence
        CandidateEndpointModes = @('chat', 'images')
        AdvertisedSizes = @($resolution.AdvertisedSizes)
        AdvertisedAspectRatios = @($resolution.AdvertisedAspectRatios)
        ResolutionSource = if (@($resolution.AdvertisedSizes).Count -gt 0 -or @($resolution.AdvertisedAspectRatios).Count -gt 0) { 'api-metadata' } else { 'not-advertised' }
        SuggestedSizes = if (@($resolution.AdvertisedSizes).Count -eq 0) { @('1024x1024', '1536x1024', '1024x1536') } else { @() }
        SuggestedAspectRatios = if (@($resolution.AdvertisedAspectRatios).Count -eq 0) { @('1:1', '16:9', '9:16', '4:3', '3:4') } else { @() }
    }
}

[pscustomobject]@{
    Endpoint = $resolvedEndpoint
    TotalModelsReturned = @($rawModels).Count
    FilteredModelCount = $models.Count
    Models = @($models | Sort-Object Id)
    Note = 'Advertised values come from API metadata. Suggested values are unverified candidates when the API publishes no resolution metadata.'
} | ConvertTo-Json -Depth 12
