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
$editOutput = Join-Path $tempRoot 'edited.png'
$fallbackOutput = Join-Path $tempRoot 'fallback-chat.png'
$highResolutionOutput = Join-Path $tempRoot 'high-resolution.png'
$fourKOutput = Join-Path $tempRoot 'four-k.png'
$fourKEditOutput = Join-Path $tempRoot 'four-k-edit.png'
$editInput = Join-Path $tempRoot 'uploaded image.png'
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

        function Find-ByteSequence {
            param([byte[]]$Buffer, [byte[]]$Needle, [int]$StartAt = 0)
            for ($i = $StartAt; $i -le $Buffer.Length - $Needle.Length; $i++) {
                $found = $true
                for ($j = 0; $j -lt $Needle.Length; $j++) {
                    if ($Buffer[$i + $j] -ne $Needle[$j]) { $found = $false; break }
                }
                if ($found) { return $i }
            }
            return -1
        }

        try {
            for ($index = 0; $index -lt 9; $index++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $raw = [IO.MemoryStream]::new()
                    $readBuffer = New-Object byte[] 8192
                    $headerDelimiter = [Text.Encoding]::ASCII.GetBytes("`r`n`r`n")
                    $headerEnd = -1
                    while ($headerEnd -lt 0) {
                        $count = $stream.Read($readBuffer, 0, $readBuffer.Length)
                        if ($count -le 0) { break }
                        $raw.Write($readBuffer, 0, $count)
                        $headerEnd = Find-ByteSequence -Buffer $raw.ToArray() -Needle $headerDelimiter
                    }
                    $allBytes = $raw.ToArray()
                    $headerText = [Text.Encoding]::ASCII.GetString($allBytes, 0, [Math]::Max(0, $headerEnd))
                    $contentLength = 0
                    if ($headerText -match '(?im)^Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
                    $authorization = $null
                    if ($headerText -match '(?im)^Authorization:\s*(.+)$') { $authorization = $Matches[1].Trim() }
                    $bodyStart = $headerEnd + $headerDelimiter.Length
                    while ($allBytes.Length - $bodyStart -lt $contentLength) {
                        $count = $stream.Read($readBuffer, 0, $readBuffer.Length)
                        if ($count -le 0) { break }
                        $raw.Write($readBuffer, 0, $count)
                        $allBytes = $raw.ToArray()
                    }
                    $bodyBytes = if ($contentLength -gt 0 -and $bodyStart -ge 0 -and $allBytes.Length -ge $bodyStart + $contentLength) { $allBytes[$bodyStart..($bodyStart + $contentLength - 1)] } else { @() }
                    $body = [Text.Encoding]::UTF8.GetString([byte[]]$bodyBytes)
                    $requestLine = ($headerText -split "`r?`n")[0]
                    $path = ($requestLine -split ' ')[1]

                    $statusCode = 200
                    if ($path -eq '/v1/images/edits' -and $body -match 'Trigger Images Edits fallback') {
                        $statusCode = 404
                        $responseBody = '{"error":{"message":"Images Edits endpoint is not supported"}}'
                    }
                    elseif ($path -eq '/v1/images/generations' -and $body -match '"size"\s*:\s*"2560x1440"' -and $body -notmatch '"model"\s*:\s*"gpt-image-2"') {
                        $statusCode = 400
                        $responseBody = '{"error":{"message":"high-resolution request must preserve gpt-image-2 model ID"}}'
                    }
                    elseif ($path -eq '/v1/images/generations' -and $body -match 'Trigger high-resolution failure') {
                        $statusCode = 400
                        $responseBody = '{"error":{"message":"model gpt-image-2 does not support 2560x1440; high-resolution unavailable"}}'
                    }
                    elseif ($path -eq '/v1/chat/completions') {
                        $responseBody = '{"choices":[{"message":{"content":"![image](data:image/png;base64,' + $pngBase64 + ')"}}]}'
                    }
                    else {
                        $responseBody = '{"data":[{"b64_json":"' + $pngBase64 + '"}]}'
                    }

                    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($responseBody)
                    $statusText = if ($statusCode -eq 200) { 'OK' } else { 'Not Found' }
                    $header = "HTTP/1.1 $statusCode $statusText`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
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

    [IO.File]::WriteAllBytes($editInput, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/69c7WQAAAABJRU5ErkJggg=='))
    $editDryRun = & $Generator `
        -Prompt 'Change only the membrane to silver.' `
        -Model 'gpt-image-2' `
        -InputImagePath $editInput `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -DryRun | ConvertFrom-Json
    Assert-True ($editDryRun.EndpointMode -eq 'images') 'known image model with reference defaults to images mode'
    Assert-True ($editDryRun.Endpoint -eq "http://127.0.0.1:$port/v1/images/edits") 'reference image uses the images edit endpoint'
    Assert-True ($editDryRun.RequestFormat -eq 'multipart/form-data') 'reference image uses multipart form data'
    Assert-True ($editDryRun.Payload.image.field -eq 'image') 'uploaded image uses the image file field'
    Assert-True ($editDryRun.Payload.image.contentType -eq 'image/png') 'uploaded image content type is detected'
    Assert-True ($editDryRun.Payload.image.bytes -gt 0) 'uploaded image metadata contains bytes'
    Assert-True ($editDryRun.Payload.prompt -match 'Preserve all content') 'images edit prompt preserves unspecified content'

    $editChatDryRun = & $Generator `
        -Prompt 'Change only the membrane to silver.' `
        -Model 'gpt-image-2' `
        -EndpointMode chat `
        -InputImagePath $editInput `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -DryRun | ConvertFrom-Json
    Assert-True ($editChatDryRun.EndpointMode -eq 'chat') 'explicit chat reference edit mode'
    Assert-True ($editChatDryRun.Payload.messages[0].content -match 'Preserve all content') 'chat edit instruction preserves unspecified content'

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

    $fourKTimeout = & $Generator `
        -Prompt '4K timeout test' `
        -Model 'gpt-image-2' `
        -Size '3840x2160' `
        -TimeoutSec 300 `
        -DryRun | ConvertFrom-Json
    Assert-True ($fourKTimeout.RequestedTimeoutSec -eq 300) '4K preserves requested timeout metadata'
    Assert-True ($fourKTimeout.TimeoutSec -eq 480) '4K timeout floor is eight minutes'

    $longerFourKTimeout = & $Generator `
        -Prompt '4K longer timeout test' `
        -Model 'gpt-image-2' `
        -Size '3840x2160' `
        -TimeoutSec 600 `
        -DryRun | ConvertFrom-Json
    Assert-True ($longerFourKTimeout.TimeoutSec -eq 600) 'explicit longer 4K timeout is preserved'

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

    $editResult = & $Generator `
        -Prompt 'Change only the membrane to silver.' `
        -Model 'gpt-image-2' `
        -InputImagePath $editInput `
        -Route auto `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -ApiKey 'ccswitch-test-key' `
        -OutputPath $editOutput | ConvertFrom-Json

    $fallbackResult = & $Generator `
        -Prompt 'Trigger Images Edits fallback: change only the membrane.' `
        -Model 'gpt-image-2' `
        -InputImagePath $editInput `
        -Route auto `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -ApiKey 'ccswitch-test-key' `
        -Size '1024x1024' `
        -OutputPath $fallbackOutput | ConvertFrom-Json

    $highResolutionResult = & $Generator `
        -Prompt 'high-resolution test' `
        -Model 'gpt-image-2' `
        -Route auto `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -ApiKey 'ccswitch-test-key' `
        -Size '2560x1440' `
        -OutputPath $highResolutionOutput | ConvertFrom-Json

    $fourKResult = & $Generator `
        -Prompt '4K high-resolution test' `
        -Model 'gpt-image-2' `
        -Route auto `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -ApiKey 'ccswitch-test-key' `
        -Size '3840x2160' `
        -OutputPath $fourKOutput | ConvertFrom-Json

    $fourKEditResult = & $Generator `
        -Prompt 'Edit this reference at 4K while preserving the composition.' `
        -Model 'gpt-image-2' `
        -InputImagePath $editInput `
        -Route auto `
        -BaseUrl "http://127.0.0.1:$port/v1" `
        -ApiKey 'ccswitch-test-key' `
        -Size '3840x2160' `
        -OutputPath $fourKEditOutput | ConvertFrom-Json

    $highResolutionFailure = $false
    try {
        & $Generator `
            -Prompt 'Trigger high-resolution failure' `
            -Model 'gpt-image-2' `
            -Route auto `
            -BaseUrl "http://127.0.0.1:$port/v1" `
            -ApiKey 'ccswitch-test-key' `
            -Size '2560x1440' `
            -OutputPath (Join-Path $tempRoot 'high-resolution-failure.png') | Out-Null
    }
    catch {
        $highResolutionFailure = $_.Exception.Message -match 'High-resolution 2K request.*no lower-resolution fallback was attempted'
    }

    Wait-Job -Job $serverJob -Timeout 10 | Out-Null
    $requests = @(Receive-Job -Job $serverJob)

    Assert-True ($chatResult.EndpointMode -eq 'chat') 'chat result mode'
    Assert-True ($imagesResult.EndpointMode -eq 'images') 'images result mode'
    Assert-True ($editResult.EndpointMode -eq 'images') 'edit result mode'
    Assert-True ($fallbackResult.EndpointMode -eq 'chat') 'Images Edits fallback result mode'
    Assert-True ($fallbackResult.Endpoint -eq "http://127.0.0.1:$port/v1/chat/completions") 'Images Edits fallback endpoint'
    Assert-True ($fallbackResult.FallbackFromEndpoint -eq "http://127.0.0.1:$port/v1/images/edits") 'Images Edits fallback source endpoint'
    Assert-True ($fallbackResult.FallbackReason -match 'HTTP 404') 'Images Edits fallback reason'
    Assert-True ($highResolutionResult.RequestedModel -eq 'gpt-image-2') 'high-resolution preserves requested model'
    Assert-True ($highResolutionResult.Model -eq 'gpt-image-2') 'high-resolution preserves model ID'
    Assert-True ($highResolutionResult.Size -eq '2560x1440') 'high-resolution keeps requested size'
    Assert-True ($fourKResult.Model -eq 'gpt-image-2') '4K preserves model ID'
    Assert-True ($fourKResult.Size -eq '3840x2160') '4K keeps requested size'
    Assert-True ($fourKResult.ResolutionTier -eq '4K') '4K resolution tier'
    Assert-True ($fourKEditResult.Operation -eq 'edit') '4K edit operation'
    Assert-True ($fourKEditResult.Model -eq 'gpt-image-2') '4K edit preserves model ID'
    Assert-True ($fourKEditResult.Size -eq '3840x2160') '4K edit keeps requested size'
    Assert-True $highResolutionFailure 'high-resolution failure explains that no lower fallback was attempted'
    Assert-True ($chatResult.NextEditInputPath -eq $chatOutput) 'chat result exposes next edit input path'
    Assert-True ($imagesResult.NextEditInputPath -eq $imagesOutput) 'images result exposes next edit input path'
    Assert-True ($editResult.NextEditInputPath -eq $editOutput) 'edit result exposes next edit input path'
    Assert-True ($chatResult.Route -eq 'codex') 'chat uses the Codex route'
    Assert-True ($imagesResult.Route -eq 'direct') 'gpt-image-2 uses the direct route'
    Assert-True ((Get-Item -LiteralPath $chatOutput).Length -gt 8) 'chat image was written'
    Assert-True ((Get-Item -LiteralPath $imagesOutput).Length -gt 8) 'images response was written'
    Assert-True ((Get-Item -LiteralPath $editOutput).Length -gt 8) 'edited response was written'
    Assert-True ((Get-Item -LiteralPath $fallbackOutput).Length -gt 8) 'fallback response was written'
    Assert-True ($requests.Count -eq 9) 'mock server received nine requests'
    Assert-True ($requests[0].Path -eq '/v1/chat/completions') 'chat request path'
    Assert-True ($requests[1].Path -eq '/v1/images/generations') 'images request path'
    Assert-True ($requests[2].Path -eq '/v1/images/edits') 'images edit request path'
    Assert-True ($requests[3].Path -eq '/v1/images/edits') 'fallback first request path'
    Assert-True ($requests[4].Path -eq '/v1/chat/completions') 'fallback chat request path'
    Assert-True ($requests[5].Path -eq '/v1/images/generations') 'high-resolution request path'
    Assert-True ($requests[6].Path -eq '/v1/images/generations') '4K request path'
    Assert-True ($requests[7].Path -eq '/v1/images/edits') '4K edit request path'
    Assert-True ($requests[8].Path -eq '/v1/images/generations') 'high-resolution failure request path'
    Assert-True ($null -eq $requests[0].Authorization) 'chat request omits authorization in no-auth mode'
    Assert-True ($requests[1].Authorization -eq 'Bearer ccswitch-test-key') 'current CCSwitch provider authorization header'

    $chatBody = $requests[0].Body | ConvertFrom-Json
    $imagesBody = $requests[1].Body | ConvertFrom-Json
    Assert-True ($chatBody.model -eq 'chat-model') 'chat model payload'
    Assert-True ($chatBody.extra_body.imageConfig.aspectRatio -eq '16:9') 'chat aspect ratio payload'
    Assert-True ($imagesBody.model -eq 'gpt-image-2') 'images model payload'
    Assert-True ($imagesBody.size -eq '1536x1024') 'images size payload'
    Assert-True ($requests[2].Body -match '(?i)(image|filename)') 'images edit multipart includes image field'
    Assert-True ($requests[2].Body -match '(?i)prompt') 'images edit multipart includes prompt field'
    $fallbackChatBody = $requests[4].Body | ConvertFrom-Json
    Assert-True ($fallbackChatBody.extra_body.imageConfig.aspectRatio -eq '1:1') 'fallback derives chat aspect ratio from size'
    Assert-True ($fallbackChatBody.messages[0].content -match 'Preserve all content') 'fallback chat preserves unspecified content'
    $highResolutionBody = $requests[5].Body | ConvertFrom-Json
    Assert-True ($highResolutionBody.model -eq 'gpt-image-2') 'high-resolution request model payload'
    Assert-True ($highResolutionBody.size -eq '2560x1440') 'high-resolution size payload'
    $fourKBody = $requests[6].Body | ConvertFrom-Json
    Assert-True ($fourKBody.model -eq 'gpt-image-2') '4K request model payload'
    Assert-True ($fourKBody.size -eq '3840x2160') '4K size payload'
    Assert-True ($requests[7].Body -match '(?i)gpt-image-2') '4K edit model payload'
    Assert-True ($requests[7].Body -match '(?i)3840x2160') '4K edit size payload'
    Assert-True ($requests[7].Body -match '(?i)(image|filename)') '4K edit includes image field'

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
