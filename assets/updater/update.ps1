# Project: DAM for Windows Tools
# File: updater/update.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-23

# 親アプリの終了後だけ検証済みファイルを置換し、失敗時は旧版へ戻して再起動します。

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][int]$ParentProcessId,
  [Parameter(Mandatory = $true)][string]$ArchivePath,
  [Parameter(Mandatory = $true)][string]$InstallDirectory,
  [Parameter(Mandatory = $true)][string]$UpdateDirectory,
  [Parameter(Mandatory = $true)][string]$DataDirectoryName,
  [Parameter(Mandatory = $true)][string]$ExecutableName,
  [Parameter(Mandatory = $true)][string]$ExpectedRootName,
  [Parameter(Mandatory = $true)][string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 基準ディレクトリの直下に収まる相対パスだけを絶対パスへ変換します。

function Get-SafeChildPath {
  param(
    [Parameter(Mandatory = $true)][string]$BaseDirectory,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )
  if ([IO.Path]::IsPathRooted($RelativePath)) {
    throw "Rooted path is not allowed: $RelativePath"
  }
  $baseFull = [IO.Path]::GetFullPath($BaseDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $targetFull = [IO.Path]::GetFullPath((Join-Path $BaseDirectory $RelativePath))
  if (-not $targetFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path escapes the expected directory: $RelativePath"
  }
  return $targetFull
}

# SHA256SUMS.txtを解析し、安全な相対パスと期待ハッシュの一覧を返します。

function Read-ReleaseManifest {
  param([Parameter(Mandatory = $true)][string]$ReleaseDirectory)
  $manifestPath = Join-Path $ReleaseDirectory 'SHA256SUMS.txt'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'SHA256SUMS.txt is missing from the release'
  }
  $entries = [Collections.Generic.List[object]]::new()
  foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if (-not $line.Trim()) { continue }
    if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') {
      throw "Invalid SHA256SUMS entry: $line"
    }
    $relativePath = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
    $null = Get-SafeChildPath -BaseDirectory $ReleaseDirectory -RelativePath $relativePath
    $entries.Add([pscustomobject]@{
      Hash = $Matches[1].ToLowerInvariant()
      RelativePath = $relativePath
    })
  }
  if ($entries.Count -eq 0) { throw 'SHA256SUMS.txt is empty' }
  return $entries
}

# マニフェスト記載ファイルが通常ファイルとしてすべて存在することを確認します。

function Assert-ReleaseFilesPresent {
  param(
    [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
    [Parameter(Mandatory = $true)][object[]]$Entries
  )
  foreach ($entry in $Entries) {
    $path = Get-SafeChildPath -BaseDirectory $ReleaseDirectory -RelativePath $entry.RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Release file is missing: $($entry.RelativePath)"
    }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Reparse points are not allowed: $($entry.RelativePath)"
    }
  }
}

# 指定された相対ファイルだけを元の階層を保って別ディレクトリへ移動します。

function Move-ReleaseFiles {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [Parameter(Mandatory = $true)][string[]]$RelativePaths
  )
  foreach ($relativePath in $RelativePaths) {
    $source = Get-SafeChildPath -BaseDirectory $SourceDirectory -RelativePath $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
    $destination = Get-SafeChildPath -BaseDirectory $DestinationDirectory -RelativePath $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Move-Item -LiteralPath $source -Destination $destination -Force
  }
}

# 指定された相対ファイルだけを元の階層を保って配布フォルダへコピーします。

function Copy-ReleaseFiles {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [Parameter(Mandatory = $true)][string[]]$RelativePaths
  )
  foreach ($relativePath in $RelativePaths) {
    $source = Get-SafeChildPath -BaseDirectory $SourceDirectory -RelativePath $relativePath
    $destination = Get-SafeChildPath -BaseDirectory $DestinationDirectory -RelativePath $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
  }
}

# 利用者データフォルダ自身または配下を更新マニフェストの対象にする記述を拒否します。

function Assert-NoProtectedPaths {
  param(
    [Parameter(Mandatory = $true)][string[]]$RelativePaths,
    [Parameter(Mandatory = $true)][string]$ProtectedDirectoryName
  )
  $prefix = $ProtectedDirectoryName.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  foreach ($relativePath in $RelativePaths) {
    if ($relativePath.Equals($ProtectedDirectoryName, [StringComparison]::OrdinalIgnoreCase) -or
        $relativePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Release manifest contains a protected data path: $relativePath"
    }
  }
}

$parentExited = $false
$newEntries = @()
$newRelativePaths = @()
$backupDirectory = $null
$installFull = [IO.Path]::GetFullPath($InstallDirectory)
$updateFull = [IO.Path]::GetFullPath($UpdateDirectory)
$installedExecutable = Join-Path $installFull $ExecutableName

try {
  $dataFull = [IO.Path]::GetFullPath((Join-Path $installFull $DataDirectoryName)).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not ($updateFull + [IO.Path]::DirectorySeparatorChar).StartsWith($dataFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Update directory is outside the application data directory'
  }
  $archiveFull = [IO.Path]::GetFullPath($ArchivePath)
  if (-not ($archiveFull.StartsWith($updateFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'Update archive is outside the update directory'
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'The application did not exit in time' }
    Start-Sleep -Milliseconds 250
  }
  $parentExited = $true

  $extractDirectory = Join-Path $updateFull 'extracted'
  $backupDirectory = Join-Path $updateFull 'backup'
  foreach ($directory in @($extractDirectory, $backupDirectory)) {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item -ItemType Directory -Path $directory | Out-Null
  }
  Expand-Archive -LiteralPath $archiveFull -DestinationPath $extractDirectory
  $newReleaseDirectory = Join-Path $extractDirectory $ExpectedRootName
  if (-not (Test-Path -LiteralPath (Join-Path $newReleaseDirectory $ExecutableName) -PathType Leaf)) {
    throw 'Updated executable is missing'
  }
  $buildInfoPath = Join-Path $newReleaseDirectory 'BUILD_INFO.json'
  $buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json
  if ($buildInfo.releaseVersion -ne $ExpectedVersion) {
    throw 'BUILD_INFO.json version does not match the requested update'
  }
  $newEntries = @(Read-ReleaseManifest -ReleaseDirectory $newReleaseDirectory)
  Assert-ReleaseFilesPresent -ReleaseDirectory $newReleaseDirectory -Entries $newEntries
  $newRelativePaths = @($newEntries | ForEach-Object { $_.RelativePath }) + @('SHA256SUMS.txt')
  Assert-NoProtectedPaths -RelativePaths $newRelativePaths -ProtectedDirectoryName $DataDirectoryName

  $oldRelativePaths = @('SHA256SUMS.txt')
  if (Test-Path -LiteralPath (Join-Path $installFull 'SHA256SUMS.txt') -PathType Leaf) {
    $oldEntries = @(Read-ReleaseManifest -ReleaseDirectory $installFull)
    $oldRelativePaths = @($oldEntries | ForEach-Object { $_.RelativePath }) + @('SHA256SUMS.txt')
  }
  Assert-NoProtectedPaths -RelativePaths $oldRelativePaths -ProtectedDirectoryName $DataDirectoryName
  Move-ReleaseFiles -SourceDirectory $installFull -DestinationDirectory $backupDirectory -RelativePaths $oldRelativePaths
  Copy-ReleaseFiles -SourceDirectory $newReleaseDirectory -DestinationDirectory $installFull -RelativePaths $newRelativePaths
  Assert-ReleaseFilesPresent -ReleaseDirectory $installFull -Entries $newEntries

  Start-Process -FilePath $installedExecutable -WorkingDirectory $installFull
  try {
    # 新版の起動後にバックアップ・更新ZIP・展開物を削除し、大きな残骸を残しません。

    Remove-Item -LiteralPath $updateFull -Recurse -Force
  }
  catch {
    # 実行中スクリプトをWindowsが保持している場合は、次回起動時の清掃へ任せます。

  }
  exit 0
}
catch {
  $errorText = "$(Get-Date -Format o)`r`n$($_ | Out-String)"
  Set-Content -LiteralPath (Join-Path $updateFull 'update-error.txt') -Value $errorText -Encoding UTF8
  if ($parentExited) {
    try {
      foreach ($relativePath in $newRelativePaths) {
        $installedPath = Get-SafeChildPath -BaseDirectory $installFull -RelativePath $relativePath
        if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
          Remove-Item -LiteralPath $installedPath -Force
        }
      }
      if ($backupDirectory -and (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        $backupFiles = Get-ChildItem -LiteralPath $backupDirectory -Recurse -File
        $backupPrefix = [IO.Path]::GetFullPath($backupDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        foreach ($backupFile in $backupFiles) {
          $relativePath = $backupFile.FullName.Substring($backupPrefix.Length)
          $destination = Get-SafeChildPath -BaseDirectory $installFull -RelativePath $relativePath
          New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
          Move-Item -LiteralPath $backupFile.FullName -Destination $destination -Force
        }
      }
      if (Test-Path -LiteralPath $installedExecutable -PathType Leaf) {
        Start-Process -FilePath $installedExecutable -WorkingDirectory $installFull
      }
    }
    catch {
      Add-Content -LiteralPath (Join-Path $updateFull 'update-error.txt') -Value "`r`nRollback failed:`r`n$($_ | Out-String)" -Encoding UTF8
    }
  }
  exit 1
}
