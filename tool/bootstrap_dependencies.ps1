# Project: DAM for Windows Tools
# File: bootstrap_dependencies.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-22

# 固定URL・SHA-256マニフェストから、再現可能なビルド依存物だけを取得します。

[CmdletBinding()]
param(
  [string]$ManifestPath = (Join-Path $PSScriptRoot 'source_inputs.json'),
  [string]$CacheRoot = (Join-Path $PSScriptRoot 'cache'),
  [ValidateRange(1, 5)][int]$RetryCount = 3
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

<# 指定ファイルのSHA-256を期待値と比較し、不一致なら直ちに停止します。 #>
function Get-VerifiedSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256
  )

  $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($actualSha256 -ne $ExpectedSha256) {
    throw "SHA-256 mismatch for $([IO.Path]::GetFileName($Path)): expected $ExpectedSha256, got $actualSha256"
  }
}

<#
HTTPS・名前・ハッシュを検証し、一時ファイル経由で依存物をキャッシュします。
失敗時は指数バックオフで指定回数だけ再試行し、未検証ファイルを残しません。
#>
function Receive-PinnedInput {
  param(
    [Parameter(Mandatory = $true)][string]$FileName,
    [Parameter(Mandatory = $true)][uri]$Uri,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][int]$MaximumAttempts
  )

  if ([IO.Path]::GetFileName($FileName) -ne $FileName -or
      $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw "Invalid dependency file name: $FileName"
  }
  if ($Uri.Scheme -ne [Uri]::UriSchemeHttps -or -not $Uri.IsAbsoluteUri) {
    throw "Dependency URL must be absolute HTTPS: $Uri"
  }
  if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$') {
    throw "Invalid SHA-256 for dependency: $FileName"
  }

  $destination = [IO.Path]::GetFullPath((Join-Path $DestinationRoot $FileName))
  $destinationPrefix = $DestinationRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $destination.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Dependency path escaped the cache directory: $destination"
  }

  if (Test-Path -LiteralPath $destination -PathType Leaf) {
    Get-VerifiedSha256 -Path $destination -ExpectedSha256 $ExpectedSha256
    Write-Host "Using cached dependency: $FileName"
    return
  }
  if (Test-Path -LiteralPath $destination) {
    throw "Dependency cache target is not a file: $destination"
  }

  $lastFailure = $null
  for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
    $temporaryPath = "$destination.download-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
      Write-Host "Downloading dependency ($attempt/$MaximumAttempts): $FileName"
      $requestParameters = @{
        Uri = $Uri.AbsoluteUri
        OutFile = $temporaryPath
        MaximumRedirection = 10
        TimeoutSec = 900
        UserAgent = 'DAMforWindowsTools-build/1.0'
      }
      if ($PSVersionTable.PSVersion.Major -lt 6) {
        $requestParameters.UseBasicParsing = $true
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      }
      $previousProgressPreference = $ProgressPreference
      try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest @requestParameters
      } finally {
        $ProgressPreference = $previousProgressPreference
      }
      if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf) -or
          (Get-Item -LiteralPath $temporaryPath).Length -eq 0) {
        throw "Dependency download was empty: $FileName"
      }
      Get-VerifiedSha256 -Path $temporaryPath -ExpectedSha256 $ExpectedSha256
      [IO.File]::Move($temporaryPath, $destination)
      Write-Host "Verified dependency: $FileName"
      return
    } catch {
      $lastFailure = $_
      if (Test-Path -LiteralPath $temporaryPath) {
        [IO.File]::Delete($temporaryPath)
      }
      if ($attempt -lt $MaximumAttempts) {
        Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
      }
    }
  }

  throw "Failed to download verified dependency $FileName after $MaximumAttempts attempts: $lastFailure"
}

$manifest = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
  throw "Dependency manifest is missing: $manifest"
}
$cache = [IO.Path]::GetFullPath($CacheRoot)
New-Item -ItemType Directory -Force -Path $cache | Out-Null

$definition = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
if ($definition.schemaVersion -ne 1 -or -not $definition.inputs -or $definition.inputs.Count -eq 0) {
  throw 'Unsupported or empty dependency manifest'
}

$seenFiles = @{}
foreach ($input in $definition.inputs) {
  $fileName = [string]$input.file
  $normalizedName = $fileName.ToLowerInvariant()
  if ($seenFiles.ContainsKey($normalizedName)) {
    throw "Duplicate dependency file name: $fileName"
  }
  $seenFiles[$normalizedName] = $true
  Receive-PinnedInput `
    -FileName $fileName `
    -Uri ([uri]$input.url) `
    -ExpectedSha256 ([string]$input.sha256).ToLowerInvariant() `
    -DestinationRoot $cache `
    -MaximumAttempts $RetryCount
}
