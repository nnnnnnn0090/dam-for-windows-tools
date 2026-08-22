# Project: DAM for Windows Tools
# File: release_helpers.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-23

function Get-RelativePathCompat {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$TargetPath
  )

  $baseFullPath = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $targetFullPath = [IO.Path]::GetFullPath($TargetPath)
  if (-not $targetFullPath.StartsWith($baseFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path is outside the expected base directory: $targetFullPath"
  }
  return $targetFullPath.Substring($baseFullPath.Length)
}

function Find-SignTool {
  if ($env:DAM_TOOLS_SIGNTOOL) {
    $configured = [IO.Path]::GetFullPath($env:DAM_TOOLS_SIGNTOOL)
    if (Test-Path -LiteralPath $configured -PathType Leaf) { return $configured }
    throw "DAM_TOOLS_SIGNTOOL does not exist: $configured"
  }
  $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $candidate = Get-ChildItem -LiteralPath $kitsRoot -Filter signtool.exe -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match '[\\/]x64$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if ($candidate) { return $candidate.FullName }
  return $null
}

function Invoke-CodeSign {
  param(
    [Parameter(Mandatory = $true)][string]$SignTool,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [Parameter(Mandatory = $true)][string[]]$Files,
    [Parameter(Mandatory = $true)][string]$Rfc3161Url
  )
  $normalizedThumbprint = $Thumbprint -replace '\s', ''
  if ($normalizedThumbprint -notmatch '^[0-9A-Fa-f]{40}$') {
    throw 'The signing certificate thumbprint must be 40 hexadecimal characters'
  }
  foreach ($file in $Files) {
    & $SignTool sign /sha1 $normalizedThumbprint /fd SHA256 /tr $Rfc3161Url /td SHA256 $file
    if ($LASTEXITCODE -ne 0) { throw "Code signing failed: $file" }
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid') { throw "Signature verification failed: $file ($($signature.Status))" }
  }
}

function Copy-RuntimePackage {
  param(
    [Parameter(Mandatory = $true)][string]$SourceModules,
    [Parameter(Mandatory = $true)][string]$DestinationModules,
    [Parameter(Mandatory = $true)][string]$PackageName,
    [Parameter(Mandatory = $true)][string[]]$Entries
  )
  $sourcePackage = Join-Path $SourceModules $PackageName
  $destinationPackage = Join-Path $DestinationModules $PackageName
  New-Item -ItemType Directory -Force -Path $destinationPackage | Out-Null
  foreach ($entry in $Entries) {
    $source = Join-Path $sourcePackage $entry
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Required runtime package entry is missing: $PackageName/$entry"
    }
    $destination = Join-Path $destinationPackage $entry
    $destinationParent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse
  }
}
