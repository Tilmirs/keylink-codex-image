[CmdletBinding()]
param(
    [string]$Installer
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

if (-not $Installer) {
    $Installer = Join-Path $PSScriptRoot '..\install.ps1'
}
$Installer = [IO.Path]::GetFullPath($Installer)
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ('keylink-install-tests-' + [Guid]::NewGuid().ToString('N'))
$codexHome = Join-Path $tempRoot 'codex-home'
$externalDirectory = Join-Path $tempRoot 'unrelated-directory'
$externalSentinel = Join-Path $externalDirectory 'keep.txt'
$credentialPath = Join-Path $codexHome 'secrets\keylink-image-api-key.txt'
$oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')

New-Item -ItemType Directory -Path $externalDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $credentialPath) -Force | Out-Null
[IO.File]::WriteAllText($externalSentinel, 'do-not-change')
[IO.File]::WriteAllText($credentialPath, 'not-a-real-key')

try {
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexHome, 'Process')

    $first = & $Installer -PassThru
    $destination = Join-Path $codexHome 'skills\keylink-image'
    Assert-True ($first.Destination -eq [IO.Path]::GetFullPath($destination)) 'first install destination'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'SKILL.md') -PathType Leaf) 'SKILL.md installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'scripts\generate_image.ps1') -PathType Leaf) 'generator installed'
    Assert-True (-not $first.BackupPath) 'first install does not create a backup'

    $installedMarker = Join-Path $destination 'old-version-marker.txt'
    [IO.File]::WriteAllText($installedMarker, 'old-version')

    $second = & $Installer -PassThru
    Assert-True ($second.BackupPath -and (Test-Path -LiteralPath $second.BackupPath -PathType Container)) 'update creates a backup'
    Assert-True (Test-Path -LiteralPath (Join-Path $second.BackupPath 'old-version-marker.txt') -PathType Leaf) 'backup preserves the old installation'
    Assert-True (-not (Test-Path -LiteralPath $installedMarker)) 'updated installation replaces old files'
    Assert-True ([IO.File]::ReadAllText($credentialPath) -eq 'not-a-real-key') 'credential outside the skill directory is preserved'
    Assert-True ([IO.File]::ReadAllText($externalSentinel) -eq 'do-not-change') 'unrelated directory is untouched'

    $expectedBackupRoot = [IO.Path]::GetFullPath((Join-Path $codexHome 'skill-backups\keylink-image'))
    Assert-True ((Split-Path -Parent $second.BackupPath) -eq $expectedBackupRoot) 'backup stays inside Codex skill-backups'

    'All Keylink installer tests passed.'
}
finally {
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHome, 'Process')
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot).StartsWith('keylink-install-tests-')) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
