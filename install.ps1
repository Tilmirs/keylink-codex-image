[CmdletBinding()]
param(
    [string]$SourcePath = $PSScriptRoot,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Assert-KeylinkSkillFolder {
    param([Parameter(Mandatory)][string]$Path)

    $requiredPaths = @(
        'SKILL.md',
        'agents\openai.yaml',
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
$sourceRoot = [IO.Path]::GetFullPath($SourcePath)
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
$backupPath = $null
$runtimeItems = @('SKILL.md', 'agents', 'scripts', 'references')

try {
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
}

Write-Host "Keylink Image installed: $destination"
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
    }
}
