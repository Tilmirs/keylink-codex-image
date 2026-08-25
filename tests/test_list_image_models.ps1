[CmdletBinding()]
param(
    [string]$Lister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

if (-not $Lister) {
    $Lister = Join-Path $PSScriptRoot '..\scripts\list_image_models.ps1'
}
$Lister = [IO.Path]::GetFullPath($Lister)
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ("keylink-model-list-tests-" + [Guid]::NewGuid().ToString('N'))
$portFile = Join-Path $tempRoot 'port.txt'
$serverJob = $null
$oldImageKey = [Environment]::GetEnvironmentVariable('KEYLINK_IMAGE_API_KEY', 'Process')

New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $serverJob = Start-Job -ArgumentList $portFile -ScriptBlock {
        param($PortFile)

        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        [IO.File]::WriteAllText($PortFile, [string]([Net.IPEndPoint]$listener.LocalEndpoint).Port)
        try {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 1024, $true)
                $requestLine = $reader.ReadLine()
                $authorization = $null
                while ($true) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($line)) { break }
                    if ($line -match '^Authorization:\s*(.+)$') { $authorization = $Matches[1] }
                }

                if (($requestLine -split ' ')[1] -ne '/v1/models') {
                    throw "Unexpected path: $requestLine"
                }
                $responseBody = '{"data":[' +
                    '{"id":"gpt-image-2","name":"GPT Image 2","capabilities":{"image_generation":true,"sizes":["1024x1024","1536x1024","4096x2160"],"aspect_ratios":["1:1","16:9"]}},' +
                    '{"id":"gemini-3-pro-image","display_name":"Gemini 3 Pro Image","supported_sizes":[{"width":1024,"height":1024},{"width":2048,"height":1152}]},' +
                    '{"id":"imagen-4","name":"Imagen 4"},' +
                    '{"id":"text-model","name":"Text Model"}' +
                    ']}'
                $bodyBytes = [Text.Encoding]::UTF8.GetBytes($responseBody)
                $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
                [pscustomobject]@{ Authorization = $authorization }
            }
            finally { $client.Dispose() }
        }
        finally { $listener.Stop() }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $portFile)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Timed out waiting for the local mock server.' }
        Start-Sleep -Milliseconds 50
    }
    $port = [int]([IO.File]::ReadAllText($portFile))
    [Environment]::SetEnvironmentVariable('KEYLINK_IMAGE_API_KEY', 'model-list-test-key', 'Process')

    $result = & $Lister `
        -BaseUrl "http://127.0.0.1:$port/v1" | ConvertFrom-Json

    Wait-Job -Job $serverJob -Timeout 10 | Out-Null
    $request = @(Receive-Job -Job $serverJob)

    Assert-True ($result.TotalModelsReturned -eq 4) 'model count from API'
    Assert-True ($result.FilteredModelCount -eq 3) 'text-only model is filtered'
    Assert-True ($result.Models[0].Id -eq 'gemini-3-pro-image' -or $result.Models[1].Id -eq 'gemini-3-pro-image') 'Gemini image model is listed'
    $gpt = @($result.Models | Where-Object Id -eq 'gpt-image-2')[0]
    $gemini = @($result.Models | Where-Object Id -eq 'gemini-3-pro-image')[0]
    $imagen = @($result.Models | Where-Object Id -eq 'imagen-4')[0]
    Assert-True ($gpt.ResolutionSource -eq 'api-metadata') 'GPT resolution metadata source'
    Assert-True (@($gpt.AdvertisedSizes) -contains '1536x1024') 'GPT advertised size'
    Assert-True (@($gpt.AdvertisedResolutionTiers.FourK) -contains '4096x2160') 'GPT 4K tier classification'
    Assert-True (@($gpt.AdvertisedAspectRatios) -contains '16:9') 'GPT advertised aspect ratio'
    Assert-True (@($gemini.AdvertisedSizes) -contains '2048x1152') 'Gemini nested size metadata'
    Assert-True (@($gemini.AdvertisedResolutionTiers.TwoK) -contains '2048x1152') 'Gemini 2K tier classification'
    Assert-True (@($imagen.SuggestedSizes) -contains '1024x1024') 'unadvertised model receives suggestions'
    Assert-True ($request.Authorization -eq 'Bearer model-list-test-key') 'model discovery authorization'

    'All Keylink model discovery tests passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('KEYLINK_IMAGE_API_KEY', $oldImageKey, 'Process')
    if ($serverJob) {
        Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
    }
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot).StartsWith('keylink-model-list-tests-')) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
