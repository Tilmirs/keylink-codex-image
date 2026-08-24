[CmdletBinding()]
param(
    [string]$KeyFile = (Join-Path $env:USERPROFILE '.codex\secrets\keylink-image-api-key.txt'),

    [ValidateSet('Process', 'User')]
    [string]$Scope = 'User',

    [Security.SecureString]$SecureApiKey,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedKeyFile = [IO.Path]::GetFullPath($KeyFile)
if ((Test-Path -LiteralPath $resolvedKeyFile) -and -not $Overwrite) {
    throw "Key file already exists: $resolvedKeyFile. Use -Overwrite to replace it."
}

if ($null -eq $SecureApiKey) {
    $SecureApiKey = Read-Host 'Keylink image API key' -AsSecureString
}

$pointer = [IntPtr]::Zero
$plainText = $null
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureApiKey)
    $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($plainText)) {
        throw 'The API key cannot be empty.'
    }

    $parent = Split-Path -Parent $resolvedKeyFile
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [IO.File]::WriteAllText($resolvedKeyFile, $plainText.Trim(), [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('KEYLINK_IMAGE_API_KEY_FILE', $resolvedKeyFile, $Scope)
}
finally {
    $plainText = $null
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

[pscustomobject]@{
    KeyFile = $resolvedKeyFile
    EnvironmentVariable = 'KEYLINK_IMAGE_API_KEY_FILE'
    Scope = $Scope
} | ConvertTo-Json -Depth 3
