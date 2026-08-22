# Project: DAM for Windows Tools
# File: test_updater.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-23

# 自動更新スクリプトが旧ファイルを除去し、利用者データを保持することを実環境で検証します。

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$releaseConfig = Get-Content -LiteralPath (Join-Path $projectRoot 'tool\release_config.json') -Raw | ConvertFrom-Json
$testVersion = $releaseConfig.releaseVersion
$buildRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build'))
$smokeRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot 'updater_smoke_test'))
$buildPrefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not ($smokeRoot + [IO.Path]::DirectorySeparatorChar).StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Unsafe updater test path: $smokeRoot"
}

# 指定ファイル群の現在ハッシュから、配布物と同形式のマニフェストを作成します。
function Write-TestManifest {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string[]]$RelativePaths
  )
  $lines = foreach ($relativePath in $RelativePaths) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Root $relativePath)).Hash.ToLowerInvariant()
    "$hash  $($relativePath.Replace('\', '/'))"
  }
  Set-Content -LiteralPath (Join-Path $Root 'SHA256SUMS.txt') -Value $lines -Encoding ascii
}

try {
  if (Test-Path -LiteralPath $smokeRoot) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
  }
  $install = New-Item -ItemType Directory -Path (Join-Path $smokeRoot 'install')
  $data = New-Item -ItemType Directory -Path (Join-Path $install 'DAMforWindowsToolsData')
  $update = New-Item -ItemType Directory -Path (Join-Path $data 'updates\case')
  Set-Content -LiteralPath (Join-Path $install 'old.txt') -Value 'old' -NoNewline
  Set-Content -LiteralPath (Join-Path $data 'settings.json') -Value '{"keep":true}' -NoNewline
  Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\whoami.exe') -Destination (Join-Path $install 'DAMforWindowsTools.exe')
  Write-TestManifest -Root $install -RelativePaths @('DAMforWindowsTools.exe', 'old.txt')

  $packageParent = New-Item -ItemType Directory -Path (Join-Path $smokeRoot 'package')
  $release = New-Item -ItemType Directory -Path (Join-Path $packageParent 'DAMforWindowsTools')
  Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\whoami.exe') -Destination (Join-Path $release 'DAMforWindowsTools.exe')
  Set-Content -LiteralPath (Join-Path $release 'new.txt') -Value 'new' -NoNewline
  Set-Content -LiteralPath (Join-Path $release 'BUILD_INFO.json') -Value "{`"releaseVersion`":`"$testVersion`"}" -NoNewline -Encoding utf8
  Write-TestManifest -Root $release -RelativePaths @('BUILD_INFO.json', 'DAMforWindowsTools.exe', 'new.txt')

  $archive = Join-Path $update "DAMforWindowsTools-$testVersion-win-x64.zip"
  Compress-Archive -LiteralPath $release -DestinationPath $archive
  $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
  & (Join-Path $projectRoot 'assets\updater\update.ps1') `
    -ParentProcessId 2147483646 `
    -ArchivePath $archive `
    -ExpectedArchiveSha256 $archiveHash `
    -InstallDirectory $install `
    -UpdateDirectory $update `
    -DataDirectoryName 'DAMforWindowsToolsData' `
    -ExecutableName 'DAMforWindowsTools.exe' `
    -ExpectedRootName 'DAMforWindowsTools' `
    -ExpectedVersion $testVersion
  if ($LASTEXITCODE -ne 0) { throw "Updater returned exit code $LASTEXITCODE" }
  if (-not (Test-Path -LiteralPath (Join-Path $install 'new.txt') -PathType Leaf)) {
    throw 'Updater did not install the new file'
  }
  if (Test-Path -LiteralPath (Join-Path $install 'old.txt')) {
    throw 'Updater did not remove the obsolete file'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $data 'settings.json') -PathType Leaf)) {
    throw 'Updater removed the user data file'
  }
  Write-Output 'Updater smoke test passed.'
}
finally {
  if (($smokeRoot + [IO.Path]::DirectorySeparatorChar).StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $smokeRoot)) {
    # 更新後に起動した検査用EXEがファイルを解放するまで、短時間だけ清掃を再試行します。
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
      try {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force
        break
      }
      catch {
        if ($attempt -eq 19) { throw }
        Start-Sleep -Milliseconds 250
      }
    }
  }
}
