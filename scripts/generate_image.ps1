[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Model,

    [ValidateSet('chat', 'images')]
    [string]$EndpointMode = 'chat',

    [ValidateSet('auto', 'direct', 'codex')]
    [string]$Route = 'auto',

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

function Resolve-KeylinkEndpoint {
    param(
        [string]$ExplicitEndpoint,
        [string]$ResolvedBaseUrl,
        [string]$Mode
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEndpoint)) {
        return $ExplicitEndpoint.Trim()
    }

    $base = $ResolvedBaseUrl
    $base = $base.TrimEnd('/')

    $route = if ($Mode -eq 'chat') { 'chat/completions' } else { 'images/generations' }
    if ($base -match '/v1$') {
        return "$base/$route"
    }
    return "$base/v1/$route"
}

function Get-DirectKeylinkBaseUrl {
    param([string]$ConfiguredBaseUrl)

    return Get-FirstNonEmptyValue @(
        $ConfiguredBaseUrl,
        (Get-EnvironmentValue 'KEYLINK_IMAGE_BASE_URL'),
        (Get-EnvironmentValue 'KEYLINK_BASE_URL'),
        'https://keylinkclub.com'
    )
}

function Test-IsLoopbackUrl {
    param([Parameter(Mandatory)][string]$Url)

    try {
        $hostName = ([Uri]$Url).Host
        return $hostName -in @('127.0.0.1', 'localhost', '::1')
    }
    catch {
        return $false
    }
}

function Get-CodexRouteBaseUrl {
    param([string]$ConfiguredProxyBaseUrl)

    $proxyOverride = Get-FirstNonEmptyValue @(
        $ConfiguredProxyBaseUrl,
        (Get-EnvironmentValue 'KEYLINK_PROXY_BASE_URL')
    )
    if ($proxyOverride) {
        return $proxyOverride
    }

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
    if (-not $providerName) {
        throw "Codex config does not declare model_provider: $configPath"
    }

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

function Get-CCSwitchDatabasePath {
    $configuredPath = Get-EnvironmentValue 'CCSWITCH_DB_PATH'
    if ($configuredPath) {
        $resolvedConfiguredPath = [IO.Path]::GetFullPath($configuredPath)
        if (-not (Test-Path -LiteralPath $resolvedConfiguredPath -PathType Leaf)) {
            throw "CCSwitch database does not exist: $resolvedConfiguredPath"
        }
        return $resolvedConfiguredPath
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

function Resolve-CCSwitchApiKey {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) {
        throw 'Reading the CCSwitch credential requires Node.js 22 or newer with node:sqlite support.'
    }

    $helperPath = Join-Path $PSScriptRoot 'read_ccswitch_credential.js'
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "CCSwitch credential helper is missing: $helperPath"
    }

    $databasePath = Get-CCSwitchDatabasePath
    $encodedOutput = @(& $node.Source $helperPath $databasePath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $safeError = Get-FirstNonEmptyValue @(($encodedOutput | ForEach-Object { [string]$_ }) -join ' ')
        throw "CCSwitch credential lookup failed: $safeError"
    }

    $encodedKey = Get-FirstNonEmptyValue @($encodedOutput | Select-Object -Last 1)
    if (-not $encodedKey) {
        throw 'CCSwitch credential lookup returned no key.'
    }
    try {
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
    if (-not $fileKey) {
        throw "API key file is empty: $resolvedPath"
    }
    return $fileKey
}

function Resolve-KeylinkApiKey {
    param(
        [string]$ExplicitKey,
        [string]$ExplicitKeyFile,
        [switch]$FromCCSwitch
    )

    $oneOffKey = Get-FirstNonEmptyValue @($ExplicitKey)
    if ($oneOffKey) {
        return $oneOffKey
    }

    $oneOffKeyFile = Get-FirstNonEmptyValue @($ExplicitKeyFile)
    if ($oneOffKeyFile) {
        return Read-KeylinkApiKeyFile $oneOffKeyFile
    }

    if ($FromCCSwitch) {
        return Resolve-CCSwitchApiKey
    }

    $environmentKey = Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'KEYLINK_IMAGE_API_KEY'),
        (Get-EnvironmentValue 'KEYLINK_API_KEY')
    )
    if ($environmentKey) {
        return $environmentKey
    }

    $environmentKeyFile = Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'KEYLINK_IMAGE_API_KEY_FILE'),
        (Get-EnvironmentValue 'KEYLINK_API_KEY_FILE')
    )
    if ($environmentKeyFile) {
        return Read-KeylinkApiKeyFile $environmentKeyFile
    }

    $defaultKeyFile = Join-Path (Get-FirstNonEmptyValue @(
        (Get-EnvironmentValue 'CODEX_HOME'),
        (Join-Path $env:USERPROFILE '.codex')
    )) 'secrets\keylink-image-api-key.txt'
    if (Test-Path -LiteralPath $defaultKeyFile -PathType Leaf) {
        return Read-KeylinkApiKeyFile $defaultKeyFile
    }

    throw 'Direct Keylink image requests require -ApiKey, -ApiKeyFile, -UseCCSwitchCredential, KEYLINK_IMAGE_API_KEY, KEYLINK_IMAGE_API_KEY_FILE, KEYLINK_API_KEY, or KEYLINK_API_KEY_FILE.'
}

function Get-ImageMimeType {
    param([Parameter(Mandatory)][string]$Path)

    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.png'  { return 'image/png' }
        '.webp' { return 'image/webp' }
        '.gif'  { return 'image/gif' }
        '.avif' { return 'image/avif' }
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        default { return 'application/octet-stream' }
    }
}

function Get-LocalImageDataUrl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Sanitize
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Input image does not exist: $resolvedPath"
    }

    $mimeType = Get-ImageMimeType $resolvedPath
    if ($Sanitize) {
        $length = (Get-Item -LiteralPath $resolvedPath).Length
        return "data:$mimeType;base64,<omitted:$length-bytes>"
    }

    $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($resolvedPath))
    return "data:$mimeType;base64,$base64"
}

function Get-ObjectProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Find-ImagePayload {
    param([Parameter(Mandatory)][object]$Response)

    $data = Get-ObjectProperty $Response 'data'
    if ($null -ne $data) {
        $first = @($data) | Select-Object -First 1
        $base64 = Get-ObjectProperty $first 'b64_json'
        if (-not [string]::IsNullOrWhiteSpace([string]$base64)) {
            return [pscustomobject]@{ Kind = 'base64'; Value = [string]$base64; MimeType = $null }
        }
        $url = Get-ObjectProperty $first 'url'
        if (-not [string]::IsNullOrWhiteSpace([string]$url)) {
            return [pscustomobject]@{ Kind = 'url'; Value = [string]$url; MimeType = $null }
        }
    }

    $responseJson = $Response | ConvertTo-Json -Depth 40 -Compress
    $dataUri = [regex]::Match(
        $responseJson,
        'data:image/(?<mime>[A-Za-z0-9.+-]+);base64,(?<data>[A-Za-z0-9+/=_-]+)'
    )
    if ($dataUri.Success) {
        return [pscustomobject]@{
            Kind = 'base64'
            Value = $dataUri.Groups['data'].Value
            MimeType = "image/$($dataUri.Groups['mime'].Value)"
        }
    }

    $urlMatches = [regex]::Matches($responseJson, 'https?://[^"''\s<>\)]+' ) |
        ForEach-Object { $_.Value.Replace('\u0026', '&').TrimEnd('\') }
    $likelyImageUrl = $urlMatches |
        Where-Object { $_ -match '(?i)(\.(png|jpe?g|webp|gif|avif)(\?|$)|/images?/|image=)' } |
        Select-Object -First 1
    if (-not $likelyImageUrl -and @($urlMatches).Count -eq 1) {
        $likelyImageUrl = @($urlMatches)[0]
    }
    if ($likelyImageUrl) {
        return [pscustomobject]@{ Kind = 'url'; Value = $likelyImageUrl; MimeType = $null }
    }

    throw 'The API response did not contain a supported image payload.'
}

function ConvertFrom-FlexibleBase64 {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = $Value.Replace('-', '+').Replace('_', '/')
    $padding = (4 - ($normalized.Length % 4)) % 4
    if ($padding -gt 0) {
        $normalized += ('=' * $padding)
    }
    return [Convert]::FromBase64String($normalized)
}

if ($InputImageUrl -and $InputImagePath) {
    throw 'Specify either -InputImageUrl or -InputImagePath, not both.'
}
if ($UseCodexRoute -and $Route -ne 'auto') {
    throw 'Do not combine the legacy -UseCodexRoute switch with -Route.'
}
if ($UseCodexRoute -and $BaseUrl) {
    throw 'Specify either -UseCodexRoute or -BaseUrl, not both.'
}
if ($ProxyBaseUrl -and $Route -eq 'direct') {
    throw '-ProxyBaseUrl applies only to auto/codex proxy routing, not -Route direct.'
}
if ($ProxyBaseUrl -and $Endpoint) {
    throw 'Specify either -ProxyBaseUrl or -Endpoint, not both.'
}
if ($UseCCSwitchCredential -and $UseCodexRoute) {
    throw 'Use -UseCCSwitchCredential only with a direct Keylink route; do not send the CCSwitch credential to its loopback proxy.'
}
if ($UseCCSwitchCredential -and $BaseUrl -and -not (([Uri]$BaseUrl).Host -ieq 'keylinkclub.com' -or ([Uri]$BaseUrl).Host.ToLowerInvariant().EndsWith('.keylinkclub.com'))) {
    throw 'Use -UseCCSwitchCredential only with a Keylink base URL.'
}
if ($UseCCSwitchCredential -and $Endpoint -and -not (([Uri]$Endpoint).Host -ieq 'keylinkclub.com' -or ([Uri]$Endpoint).Host.ToLowerInvariant().EndsWith('.keylinkclub.com'))) {
    throw 'Use -UseCCSwitchCredential only with a Keylink endpoint.'
}
if ($NoAuth -and ($ApiKey -or $ApiKeyFile -or $UseCCSwitchCredential)) {
    throw 'Do not combine -NoAuth with an API key source.'
}
$endpointModeWasExplicit = $PSBoundParameters.ContainsKey('EndpointMode')
$knownImageModels = @(
    'gpt-image-2',
    'gemini-3-pro-image',
    'gemini-2.5-flash-image',
    'gemini-3.1-flash-image'
)
$isKnownImageModel = @($knownImageModels | Where-Object { $_ -ieq $Model }).Count -gt 0
if (-not $endpointModeWasExplicit -and $isKnownImageModel) {
    $EndpointMode = 'images'
}

if ($EndpointMode -eq 'images' -and ($InputImageUrl -or $InputImagePath)) {
    throw 'The images mode in this helper is text-to-image only. Use -EndpointMode chat for a reference image.'
}
if ($EndpointMode -eq 'chat' -and $Size) {
    throw 'The chat endpoint uses -AspectRatio when supported; -Size is only sent in images mode.'
}
if ($EndpointMode -eq 'images' -and $AspectRatio) {
    throw 'The images endpoint uses -Size in this helper; use -EndpointMode chat for -AspectRatio.'
}

$effectiveRoute = $Route
if ($UseCodexRoute) {
    $effectiveRoute = 'codex'
}
elseif ($Endpoint) {
    $effectiveRoute = 'custom'
}
elseif ($Route -eq 'auto') {
    if ($BaseUrl -or $EndpointMode -eq 'images') {
        $effectiveRoute = 'direct'
    }
    else {
        try {
            [void](Get-CodexRouteBaseUrl $ProxyBaseUrl)
            $effectiveRoute = 'codex'
        }
        catch {
            $effectiveRoute = 'direct'
        }
    }
}

if ($effectiveRoute -eq 'codex' -and $BaseUrl) {
    throw 'A Codex route reads its base URL from config.toml; do not also pass -BaseUrl.'
}

$resolvedBaseUrl = if ($effectiveRoute -eq 'codex') {
    Get-CodexRouteBaseUrl $ProxyBaseUrl
}
else {
    Get-DirectKeylinkBaseUrl $BaseUrl
}
$resolvedEndpoint = Resolve-KeylinkEndpoint $Endpoint $resolvedBaseUrl $EndpointMode
if ($UseCCSwitchCredential) {
    if ($effectiveRoute -notin @('direct', 'custom')) {
        throw 'Use -UseCCSwitchCredential only with a direct Keylink route.'
    }
    $credentialDestinationHost = ([Uri]$resolvedEndpoint).Host.ToLowerInvariant()
    if ($credentialDestinationHost -ne 'keylinkclub.com' -and -not $credentialDestinationHost.EndsWith('.keylinkclub.com')) {
        throw 'The CCSwitch credential can only be sent to keylinkclub.com.'
    }
}
$effectiveNoAuth = $NoAuth -or (
    $effectiveRoute -eq 'codex' -and
    (Test-IsLoopbackUrl $resolvedEndpoint) -and
    -not $ApiKey -and
    -not $ApiKeyFile
)
$content = @([ordered]@{ type = 'text'; text = $Prompt })

if ($EndpointMode -eq 'chat') {
    if ($InputImageUrl) {
        $content += [ordered]@{ type = 'image_url'; image_url = [ordered]@{ url = $InputImageUrl } }
    }
    elseif ($InputImagePath) {
        $dataUrl = Get-LocalImageDataUrl -Path $InputImagePath -Sanitize:$DryRun
        $content += [ordered]@{ type = 'image_url'; image_url = [ordered]@{ url = $dataUrl } }
    }

    $messages = @()
    if ($AspectRatio) {
        $imageConfiguration = [ordered]@{ imageConfig = [ordered]@{ aspectRatio = $AspectRatio } }
        $messages += [ordered]@{
            role = 'system'
            content = ($imageConfiguration | ConvertTo-Json -Depth 5 -Compress)
        }
    }
    $messages += [ordered]@{ role = 'user'; content = $content }

    $payload = [ordered]@{ model = $Model; messages = $messages }
    if ($AspectRatio) {
        $payload['extra_body'] = $imageConfiguration
    }
}
else {
    $payload = [ordered]@{ model = $Model; prompt = $Prompt; n = 1 }
    if ($Size) { $payload['size'] = $Size }
    if ($Quality) { $payload['quality'] = $Quality }
    if ($Background) { $payload['background'] = $Background }
    if ($OutputFormat) { $payload['output_format'] = $OutputFormat }
    if ($ResponseFormat) { $payload['response_format'] = $ResponseFormat }
}

if ($DryRun) {
    [pscustomobject]@{
        EndpointMode = $EndpointMode
        Route = $effectiveRoute
        Endpoint = $resolvedEndpoint
        Payload = $payload
    } | ConvertTo-Json -Depth 20
    return
}

if (-not $OutputPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $extension = if ($OutputFormat) { $OutputFormat.TrimStart('.') } else { 'png' }
    $OutputPath = Join-Path (Get-Location) "keylink-image-$timestamp.$extension"
}

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $OutputPath) -and -not $Overwrite) {
    throw "Output file already exists: $OutputPath. Use -Overwrite to replace it."
}

$apiKey = if ($effectiveNoAuth) { $null } else { Resolve-KeylinkApiKey $ApiKey $ApiKeyFile -FromCCSwitch:$UseCCSwitchCredential }
$headers = @{}
if ($apiKey) {
    $headers.Authorization = "Bearer $apiKey"
}
$requestJson = $payload | ConvertTo-Json -Depth 20 -Compress

try {
    $response = Invoke-RestMethod `
        -Uri $resolvedEndpoint `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($requestJson)) `
        -TimeoutSec $TimeoutSec
}
catch {
    $errorDetails = Get-ObjectProperty $_ 'ErrorDetails'
    $exception = Get-ObjectProperty $_ 'Exception'
    $details = Get-FirstNonEmptyValue @(
        (Get-ObjectProperty $errorDetails 'Message'),
        (Get-ObjectProperty $exception 'Message'),
        [string]$_
    )
    if ($apiKey) {
        $details = $details.Replace($apiKey, '<redacted>')
    }
    throw "Keylink request failed: $details"
}

try {
    $imagePayload = Find-ImagePayload $response
}
catch {
    $preview = ($response | ConvertTo-Json -Depth 12 -Compress)
    if ($preview.Length -gt 1000) {
        $preview = $preview.Substring(0, 1000) + '...'
    }
    throw "$($_.Exception.Message) Response preview: $preview"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

if ($imagePayload.Kind -eq 'base64') {
    [IO.File]::WriteAllBytes($OutputPath, (ConvertFrom-FlexibleBase64 $imagePayload.Value))
}
else {
    $downloadHeaders = @{}
    if ($apiKey -and ([Uri]$imagePayload.Value).Host -eq ([Uri]$resolvedEndpoint).Host) {
        $downloadHeaders.Authorization = "Bearer $apiKey"
    }
    Invoke-WebRequest `
        -Uri $imagePayload.Value `
        -Headers $downloadHeaders `
        -OutFile $OutputPath `
        -UseBasicParsing `
        -TimeoutSec $TimeoutSec | Out-Null
}

$savedFile = Get-Item -LiteralPath $OutputPath
if ($savedFile.Length -eq 0) {
    throw "The saved image is empty: $OutputPath"
}

[pscustomobject]@{
    OutputPath = $savedFile.FullName
    Bytes = $savedFile.Length
    Model = $Model
    EndpointMode = $EndpointMode
    Route = $effectiveRoute
    Endpoint = $resolvedEndpoint
} | ConvertTo-Json -Depth 5
