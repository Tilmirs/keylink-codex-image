[CmdletBinding()]
param(
    [string]$Generator
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

if (-not $Generator) {
    $Generator = Join-Path $PSScriptRoot '..\scripts\generate_image.ps1'
}
$Generator = [IO.Path]::GetFullPath($Generator)
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ("keylink-image-tests-" + [Guid]::NewGuid().ToString('N'))
$portFile = Join-Path $tempRoot 'port.txt'
$chatOutput = Join-Path $tempRoot 'chat.png'
$imagesOutput = Join-Path $tempRoot 'images.png'
$ccswitchDatabase = Join-Path $tempRoot 'cc-switch.db'
$serverJob = $null
$oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
$oldImageKey = [Environment]::GetEnvironmentVariable('KEYLINK_IMAGE_API_KEY', 'Process')
$oldCCSwitchDatabase = [Environment]::GetEnvironmentVariable('CCSWITCH_DB_PATH', 'Process')
$oldProxyBaseUrl = [Environment]::GetEnvironmentVariable('KEYLINK_PROXY_BASE_URL', 'Process')

New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $serverJob = Start-Job -ArgumentList $portFile -ScriptBlock {
        param($PortFile)

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        [IO.File]::WriteAllText($PortFile, [string]$port)
        $pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/69c7WQAAAABJRU5ErkJggg=='

        try {
            for ($index = 0; $index -lt 2; $index++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 1024, $true)
                    $requestLine = $reader.ReadLine()
                    $contentLength = 0
                    $authorization = $null

                    while ($true) {
                        $line = $reader.ReadLine()
                        if ([string]::IsNullOrEmpty($line)) { break }
                        if ($line -match '^Content-Length:\s*(\d+)$') {
                            $contentLength = [int]$Matches[1]
                        }
                        if ($line -match '^Authorization:\s*(.+)$') {
                            $authorization = $Matches[1]
                        }
                    }

                    $buffer = New-Object char[] $contentLength
                    $read = 0
                    while ($read -lt $contentLength) {
                        $count = $reader.ReadBlock($buffer, $read, $contentLength - $read)
                        if ($count -le 0) { break }
                        $read += $count
                    }
                    $body = -join $buffer[0..([Math]::Max(0, $read - 1))]
                    $path = ($requestLine -split ' ')[1]

                    if ($path -eq '/v1/chat/completions') {
                        $responseBody = '{"choices":[{"message":{"content":"![image](data:image/png;base64,' + $pngBase64 + ')"}}]}'
                    }
                    else {
                        $responseBody = '{"data":[{"b64_json":"' + $pngBase64 + '"}]}'
                    }

                    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($responseBody)
                    $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                    $stream.Flush()

                    [pscustomobject]@{
                        Path = $path
                        Authorization = $authorization
                        Body = $body
                    }
                }
                finally {
                    $client.Dispose()
                }
            }
        }
        finally {
            $listener.Stop()
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $portFile)) {
        if ([DateTime]::UtcNow -gt $deadline) {
            throw 'Timed out waiting for the local mock server.'
        }
        Start-Sleep -Milliseconds 50
    }
    $port = [int]([IO.File]::ReadAllText($portFile))

    $codexHome = Join-Path $tempRoot 'codex-home'
    New-Item -ItemType Directory -Path $codexHome | Out-Null
    $codexConfig = @"
model_provider = "mock"

[model_providers.mock]
base_url = "http://127.0.0.1:9/v1"
"@
    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), $codexConfig)
    $node = Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1
    & $node.Source (Join-Path $PSScriptRoot 'create_mock_ccswitch_db.js') $ccswitchDatabase 'ccswitch-test-key'
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the mock CCSwitch database.'
    }
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexHome, 'Process')
    [Environment]::SetEnvironmentVariable('KEYLINK_IMAGE_API_KEY', 'environment-test-key', 'Process')
    [Environment]::SetEnvironmentVariable('CCSWITCH_DB_PATH', $ccswitchDatabase, 'Process')
    [Environment]::SetEnvironmentVariable('KEYLINK_PROXY_BASE_URL', $null, 'Process')

    $encodedCredential = [string](& $node.Source (Join-Path (Split-Path -Parent $Generator) 'read_ccswitch_credential.js') $ccswitchDatabase)
    Assert-True ($encodedCredential -ne 'ccswitch-test-key') 'CCSwitch helper does not print the plaintext credential'
    $decodedCredential = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedCredential))
    Assert-True ($decodedCredential -eq 'ccswitch-test-key') 'CCSwitch helper selects the current Codex provider credential'

    $unsafeDestinationRejected = $false
    try {
        & $Generator `
            -Prompt 'unsafe route test' `
            -Model 'gpt-image-2' `
            -Route direct `
            -BaseUrl 'https://example.com/v1' `
            -UseCCSwitchCredential `
            -DryRun | Out-Null
    }
    catch {
        $unsafeDestinationRejected = $_.Exception.Message -match 'Keylink base URL|only be sent to keylinkclub.com'
    }
    Assert-True $unsafeDestinationRejected 'CCSwitch credential rejects non-Keylink destinations'

    [Environment]::SetEnvironmentVariable('KEYLINK_PROXY_BASE_URL', "http://127.0.0.1:$port/v1", 'Process')
    $environmentProxy = & $Generator `
        -Prompt 'environment proxy test' `
        -Model 'chat-model' `
        -EndpointMode chat `
        -Route codex `
        -DryRun | ConvertFrom-Json
    Assert-True ($environmentProxy.Endpoint -eq "http://127.0.0.1:$port/v1/chat/completions") 'environment proxy override'

    [Environment]::SetEnvironmentVariable('KEYLINK_PROXY_BASE_URL', 'http://127.0.0.1:8/v1', 'Process')
    $explicitProxy = & $Generator `
        -Prompt 'explicit proxy test' `
        -Model 'chat-model' `
        -EndpointMode chat `
        -Route codex `
        -ProxyBaseUrl "http://127.0.0.1:$port/v1" `
        -DryRun | ConvertFrom-Json
    Assert-True ($explicitProxy.Endpoint -eq "http://127.0.0.1:$port/v1/chat/completions") 'explicit proxy overrides the environment'
    [Environment]::SetEnvironmentVariable('KEYLINK_PROXY_BASE_URL', $null, 'Process')

    $knownImageModels = @(
        'gpt-image-2',
        'gemini-3-pro-image',
        'gemini-2.5-flash-image',
        'gemini-3.1-flash-image'
    )
    foreach ($model in $knownImageModels) {
        $autoImages = & $Generator `
            -Prompt 'route test' `
            -Model $model `
            -Route auto `
            -BaseUrl "http://127.0.0.1:$port/v1" `
            -DryRun | ConvertFrom-Json
        Assert-True ($autoImages.EndpointMode -eq 'images') "$model defaults to images mode"
        Assert-True ($autoImages.Route -eq 'direct') "$model images route is direct"
        Assert-True ($autoImages.Endpoint -eq "http://127.0.0.1:$port/v1/images/generations") "$model images endpoint"
        Assert-True ($autoImages.Payload.model -eq $model) "$model images payload"

        $explicitChat = & $Generator `
            -Prompt 'route test' `
            -Model $model `
            -EndpointMode chat `
            -Route auto `
            -ProxyBaseUrl "http://127.0.0.1:$port/v1" `
            -DryRun | ConvertFrom-Json
        Assert-True ($explicitChat.EndpointMode -eq 'chat') "$model supports explicit chat mode"
        Assert-True ($explicitChat.Route -eq 'codex') "$model explicit chat uses proxy"
        Assert-True ($explicitChat.Endpoint -eq "http://127.0.0.1:$port/v1/chat/completions") "$model chat endpoint"
        Assert-True ($explicitChat.Payload.model -eq $model) "$model chat payload"
    }

    $chatSizeRejected = $false
    try {
        & $Generator -Prompt 'invalid size test' -Model 'chat-model' -EndpointMode chat -Size '1536x1024' -DryRun | Out-Null
    }
    catch { $chatSizeRejected = $_.Exception.Message -match 'AspectRatio|Size' }
    Assert-True $chatSizeRejected 'chat size is rejected instead of silently ignored'

    $imagesRatioRejected = $false
    try {
        & $Generator -Prompt 'invalid ratio test' -Model 'gpt-image-2' -EndpointMode images -AspectRatio '16:9' -DryRun | Out-Null
    }
    catch { $imagesRatioRejected = $_.Exception.Message -match 'Size|AspectRatio' }
    Assert-True $imagesRatioRejected 'images aspect ratio is rejected instead of silently ignored'

    $chatResult = & $Generator `
        -Prompt 'chat test' `
        -Model 'chat-model' `
        -AspectRatio '16:9' `
        -Route codex `
        -ProxyBaseUrl "http://127.0.0.1:$port/v1" `
        -OutputPath $chatOutput | ConvertFrom-Json

    $imagesResult = & $Generator `
        -Prompt 'images test' `
        -Model 'gpt-image-2' `
        -Route auto `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -ApiKey 'ccswitch-test-key' `
        -Size '1536x1024' `
        -OutputPath $imagesOutput | ConvertFrom-Json

    Wait-Job -Job $serverJob -Timeout 10 | Out-Null
    $requests = @(Receive-Job -Job $serverJob)

    Assert-True ($chatResult.EndpointMode -eq 'chat') 'chat result mode'
    Assert-True ($imagesResult.EndpointMode -eq 'images') 'images result mode'
    Assert-True ($chatResult.Route -eq 'codex') 'chat uses the Codex route'
    Assert-True ($imagesResult.Route -eq 'direct') 'gpt-image-2 uses the direct route'
    Assert-True ((Get-Item -LiteralPath $chatOutput).Length -gt 8) 'chat image was written'
    Assert-True ((Get-Item -LiteralPath $imagesOutput).Length -gt 8) 'images response was written'
    Assert-True ($requests.Count -eq 2) 'mock server received two requests'
    Assert-True ($requests[0].Path -eq '/v1/chat/completions') 'chat request path'
    Assert-True ($requests[1].Path -eq '/v1/images/generations') 'images request path'
    Assert-True ($null -eq $requests[0].Authorization) 'chat request omits authorization in no-auth mode'
    Assert-True ($requests[1].Authorization -eq 'Bearer ccswitch-test-key') 'current CCSwitch provider authorization header'

    $chatBody = $requests[0].Body | ConvertFrom-Json
    $imagesBody = $requests[1].Body | ConvertFrom-Json
    Assert-True ($chatBody.model -eq 'chat-model') 'chat model payload'
    Assert-True ($chatBody.extra_body.imageConfig.aspectRatio -eq '16:9') 'chat aspect ratio payload'
    Assert-True ($imagesBody.model -eq 'gpt-image-2') 'images model payload'
    Assert-True ($imagesBody.size -eq '1536x1024') 'images size payload'

    'All Keylink image helper tests passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHome, 'Process')
    [Environment]::SetEnvironmentVariable('KEYLINK_IMAGE_API_KEY', $oldImageKey, 'Process')
    [Environment]::SetEnvironmentVariable('CCSWITCH_DB_PATH', $oldCCSwitchDatabase, 'Process')
    [Environment]::SetEnvironmentVariable('KEYLINK_PROXY_BASE_URL', $oldProxyBaseUrl, 'Process')
    if ($serverJob) {
        Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
    }
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot).StartsWith('keylink-image-tests-')) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
