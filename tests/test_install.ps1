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
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'scripts\generate_image.js') -PathType Leaf) 'cross-platform generator installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'scripts\generate_image.ps1') -PathType Leaf) 'PowerShell generator installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'install.ps1') -PathType Leaf) 'PowerShell updater installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'install.sh') -PathType Leaf) 'Unix updater installed'
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

    $archiveSkill = Join-Path $tempRoot 'keylink-codex-image-main'
    $archivePath = Join-Path $tempRoot 'keylink-codex-image-main.zip'
    $remoteCodexHome = Join-Path $tempRoot 'remote-codex-home'
    New-Item -ItemType Directory -Path $archiveSkill | Out-Null
    foreach ($item in @('SKILL.md', 'install.ps1', 'install.sh')) {
        Copy-Item -LiteralPath (Join-Path $Installer "..\$item") -Destination $archiveSkill -Force
    }
    foreach ($directory in @('agents', 'scripts', 'references')) {
        Copy-Item -LiteralPath (Join-Path $Installer "..\$directory") -Destination $archiveSkill -Recurse -Force
    }
    Compress-Archive -LiteralPath $archiveSkill -DestinationPath $archivePath -Force
    $archiveUrl = ([Uri]$archivePath).AbsoluteUri

    [Environment]::SetEnvironmentVariable('CODEX_HOME', $remoteCodexHome, 'Process')
    $remoteFirst = & $Installer -Remote -ArchiveUrl $archiveUrl -PassThru
    $remoteDestination = Join-Path $remoteCodexHome 'skills\keylink-image'
    Assert-True ($remoteFirst.Destination -eq [IO.Path]::GetFullPath($remoteDestination)) 'remote install destination'
    Assert-True ($remoteFirst.Source -eq 'GitHub main branch') 'remote install source'
    Assert-True (Test-Path -LiteralPath (Join-Path $remoteDestination 'SKILL.md') -PathType Leaf) 'remote SKILL.md installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $remoteDestination 'install.ps1') -PathType Leaf) 'remote updater installed'

    $remoteMarker = Join-Path $remoteDestination 'old-version-marker.txt'
    [IO.File]::WriteAllText($remoteMarker, 'old-remote-version')
    $installedUpdater = Join-Path $remoteDestination 'install.ps1'
    $remoteSecond = & $installedUpdater -Remote -ArchiveUrl $archiveUrl -PassThru
    Assert-True ($remoteSecond.BackupPath -and (Test-Path -LiteralPath $remoteSecond.BackupPath -PathType Container)) 'remote update creates a backup'
    Assert-True (Test-Path -LiteralPath (Join-Path $remoteSecond.BackupPath 'old-version-marker.txt') -PathType Leaf) 'remote backup preserves old installation'
    Assert-True (-not (Test-Path -LiteralPath $remoteMarker)) 'remote update replaces old files'

    $remoteSentinel = Join-Path $remoteDestination 'must-survive-invalid-update.txt'
    [IO.File]::WriteAllText($remoteSentinel, 'keep-current-version')
    $invalidSkill = Join-Path $tempRoot 'invalid-skill'
    $invalidArchivePath = Join-Path $tempRoot 'invalid-skill.zip'
    New-Item -ItemType Directory -Path $invalidSkill | Out-Null
    [IO.File]::WriteAllText((Join-Path $invalidSkill 'SKILL.md'), "---`nname: keylink-image`ndescription: invalid test package`n---`n")
    Compress-Archive -LiteralPath $invalidSkill -DestinationPath $invalidArchivePath -Force
    $invalidUpdateFailed = $false
    try {
        & $installedUpdater -Remote -ArchiveUrl ([Uri]$invalidArchivePath).AbsoluteUri | Out-Null
    }
    catch {
        $invalidUpdateFailed = $true
    }
    Assert-True $invalidUpdateFailed 'invalid remote package is rejected'
    Assert-True ([IO.File]::ReadAllText($remoteSentinel) -eq 'keep-current-version') 'invalid update preserves current installation'

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
