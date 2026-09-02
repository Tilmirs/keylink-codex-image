[CmdletBinding()]
param(
    [string]$SourcePath,
    [switch]$Remote,
    [string]$ArchiveUrl,
    [string]$ProxyUrl,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$remoteDownloadRoot = $null
$remoteSource = $false

function Get-FirstEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }
    return $null
}

function Get-ConfiguredProxyUrl {
    if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
        return $ProxyUrl.Trim()
    }

    foreach ($name in @('KEYLINK_IMAGE_PROXY_URL', 'HTTPS_PROXY', 'HTTP_PROXY')) {
        $candidate = Get-FirstEnvironmentValue -Name $name
        if ($candidate -and $candidate -match '^https?://') {
            return $candidate
        }
    }
    return $null
}

function Remove-SafeTemporaryDirectory {
    param(
        [Parameter(Mandatory)][AllowNull()][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParent,
        [Parameter(Mandatory)][string]$ExpectedPrefix
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedParent = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedPath)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $expectedResolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $leaf = Split-Path -Leaf $resolvedPath
    if ($resolvedParent -ne $expectedResolvedParent -or -not $leaf.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal)) {
        throw "Refusing to remove an unexpected temporary directory: $resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Get-RemoteSkillSource {
    param([Parameter(Mandatory)][string]$Url)

    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $downloadRoot = Join-Path $tempParent ('.keylink-image.remote-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $archivePath = Join-Path $downloadRoot 'source.zip'

    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -eq 'file') {
            Copy-Item -LiteralPath $uri.LocalPath -Destination $archivePath -Force
        }
        else {
            $request = @{
                Uri = $Url
                OutFile = $archivePath
                UseBasicParsing = $true
            }
            $proxy = Get-ConfiguredProxyUrl
            if ($proxy) {
                $request.Proxy = $proxy
            }
            Invoke-WebRequest @request
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $downloadRoot -Force
        $candidates = @(Get-ChildItem -LiteralPath $downloadRoot -Directory | Where-Object { $_.Name -ne 'source' })
        if ($candidates.Count -ne 1) {
            throw 'The downloaded archive must contain exactly one skill directory.'
        }
        return [pscustomobject]@{
            Root = $candidates[0].FullName
            DownloadRoot = $downloadRoot
        }
    }
    catch {
        Remove-SafeTemporaryDirectory -Path $downloadRoot -ExpectedParent $tempParent -ExpectedPrefix '.keylink-image.remote-'
        throw
    }
}

function Assert-KeylinkSkillFolder {
    param([Parameter(Mandatory)][string]$Path)

    $requiredPaths = @(
        'SKILL.md',
        'agents\openai.yaml',
        'install.ps1',
        'install.sh',
        'scripts\generate_image.js',
        'scripts\keylink_common.js',
        'scripts\list_image_models.js',
        'scripts\generate_image.ps1',
        'scripts\list_image_models.ps1',
        'scripts\read_ccswitch_credential.js',
        'references\api.md',
        'references\troubleshooting.md'
    )

    foreach ($relativePath in $requiredPaths) {
        $candidate = Join-Path $Path $relativePath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Skill package is incomplete. Missing: $relativePath"
        }
    }

    $lines = @(Get-Content -LiteralPath (Join-Path $Path 'SKILL.md'))
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw 'SKILL.md does not contain valid YAML frontmatter.'
    }

    $frontmatter = [Collections.Generic.List[string]]::new()
    $frontmatterClosed = $false
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '---') {
            $frontmatterClosed = $true
            break
        }
        $frontmatter.Add($lines[$index])
    }

    if (-not $frontmatterClosed -or (($frontmatter -join "`n") -notmatch '(?m)^name:\s*keylink-image\s*$')) {
        throw 'SKILL.md frontmatter must declare name: keylink-image.'
    }
}

$skillName = 'keylink-image'
$sourceRoot = $null
$stagingPath = $null
$backupPath = $null

try {
    if ($Remote) {
        if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
            throw 'Do not combine -Remote with -SourcePath.'
        }
        if ([string]::IsNullOrWhiteSpace($ArchiveUrl)) {
            $ArchiveUrl = 'https://github.com/Tilmirs/keylink-codex-image/archive/refs/heads/main.zip'
        }
        $remotePackage = Get-RemoteSkillSource -Url $ArchiveUrl
        $remoteDownloadRoot = $remotePackage.DownloadRoot
        $sourceRoot = $remotePackage.Root
        $remoteSource = $true
    }
    elseif ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $sourceRoot = $PSScriptRoot
    }
    else {
        $sourceRoot = $SourcePath
    }
    $sourceRoot = [IO.Path]::GetFullPath($sourceRoot)
    Assert-KeylinkSkillFolder -Path $sourceRoot

    $configuredCodexHome = Get-FirstEnvironmentValue -Name 'CODEX_HOME'
    if (-not $configuredCodexHome) {
        if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            throw 'Neither CODEX_HOME nor USERPROFILE is available.'
        }
        $configuredCodexHome = Join-Path $env:USERPROFILE '.codex'
    }

    $codexHome = [IO.Path]::GetFullPath($configuredCodexHome)
    $skillsRoot = [IO.Path]::GetFullPath((Join-Path $codexHome 'skills'))
    $destination = [IO.Path]::GetFullPath((Join-Path $skillsRoot $skillName))

    if ($sourceRoot.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The source package is already the installed destination.'
    }
    if ((Split-Path -Parent $destination) -ne $skillsRoot -or (Split-Path -Leaf $destination) -ne $skillName) {
        throw 'Refusing to install outside the expected Codex skills directory.'
    }

    New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null

    $stagingPath = Join-Path $skillsRoot ('.keylink-image.install-' + [Guid]::NewGuid().ToString('N'))
    $runtimeItems = @('SKILL.md', 'agents', 'scripts', 'references', 'install.ps1', 'install.sh')
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    foreach ($item in $runtimeItems) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $item) -Destination $stagingPath -Recurse -Force
    }
    Assert-KeylinkSkillFolder -Path $stagingPath

    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            throw "Install destination exists but is not a directory: $destination"
        }

        $backupRoot = Join-Path $codexHome 'skill-backups\keylink-image'
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backupName = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $backupPath = Join-Path $backupRoot $backupName
        Move-Item -LiteralPath $destination -Destination $backupPath
    }

    try {
        Move-Item -LiteralPath $stagingPath -Destination $destination
    }
    catch {
        $installError = $_
        if ($backupPath -and (Test-Path -LiteralPath $backupPath -PathType Container) -and
            -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $backupPath -Destination $destination
            $backupPath = $null
        }
        throw $installError
    }
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        $safeStagingParent = Split-Path -Parent $stagingPath
        $safeStagingLeaf = Split-Path -Leaf $stagingPath
        if ($safeStagingParent -eq $skillsRoot -and $safeStagingLeaf.StartsWith('.keylink-image.install-')) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
    }
    if ($remoteDownloadRoot) {
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        Remove-SafeTemporaryDirectory -Path $remoteDownloadRoot -ExpectedParent $tempParent -ExpectedPrefix '.keylink-image.remote-'
    }
}

Write-Host "Keylink Image installed: $destination"
if ($remoteSource) {
    Write-Host 'Source: GitHub main branch'
}
if ($backupPath) {
    Write-Host "Previous version backed up: $backupPath"
}
Write-Host 'The skill will be available to Codex on the next turn; restart Codex if it is not discovered.'

if ($PassThru) {
    [pscustomobject]@{
        SkillName = $skillName
        Destination = $destination
        BackupPath = $backupPath
        CodexHome = $codexHome
        Source = if ($remoteSource) { 'GitHub main branch' } else { 'Local package' }
    }
}
