# Project: DAM for Windows Tools
# File: msvc_runtime.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-22

Set-StrictMode -Version Latest

function Assert-MicrosoftSignedFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne 'Valid' -or
      -not $signature.SignerCertificate -or
      $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
    throw "Microsoft Authenticode signature validation failed: $Path ($($signature.Status))"
  }
}

function Find-VisualCppAppLocalRuntime {
  param([Parameter(Mandatory = $true)][string[]]$RequiredFiles)

  if (-not $RequiredFiles -or $RequiredFiles.Count -eq 0) {
    throw 'At least one Visual C++ runtime file is required'
  }
  foreach ($fileName in $RequiredFiles) {
    if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notmatch '^[A-Za-z0-9._-]+\.dll$') {
      throw "Invalid Visual C++ runtime file name: $fileName"
    }
  }

  $vswhere = if ($env:DAM_TOOLS_VSWHERE) {
    [IO.Path]::GetFullPath($env:DAM_TOOLS_VSWHERE)
  } else {
    Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  }
  if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "vswhere.exe was not found: $vswhere"
  }

  $installationOutput = @(& $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath)
  $vswhereSucceeded = $?
  $installationPath = [string]($installationOutput | Select-Object -First 1)
  if (-not $vswhereSucceeded -or -not $installationPath) {
    throw 'A licensed Visual Studio installation with x64 C++ build tools is required'
  }
  $installationPath = $installationPath.Trim()
  $redistRoot = Join-Path $installationPath 'VC\Redist\MSVC'
  if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
    throw "Visual C++ Redistributable directory is missing: $redistRoot"
  }

  $candidates = foreach ($versionDirectory in Get-ChildItem -LiteralPath $redistRoot -Directory) {
    $toolsetVersion = $null
    if (-not [version]::TryParse($versionDirectory.Name, [ref]$toolsetVersion)) { continue }
    $x64Root = Join-Path $versionDirectory.FullName 'x64'
    if (-not (Test-Path -LiteralPath $x64Root -PathType Container)) { continue }
    foreach ($crtDirectory in Get-ChildItem -LiteralPath $x64Root -Directory -Filter 'Microsoft.VC*.CRT') {
      [pscustomobject]@{
        ToolsetVersion = $toolsetVersion
        Directory = $crtDirectory.FullName
      }
    }
  }

  foreach ($candidate in $candidates | Sort-Object ToolsetVersion -Descending) {
    $files = @()
    $validCandidate = $true
    foreach ($fileName in $RequiredFiles) {
      $file = Join-Path $candidate.Directory $fileName
      if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $validCandidate = $false
        break
      }
      try {
        Assert-MicrosoftSignedFile -Path $file
      } catch {
        $validCandidate = $false
        break
      }
      $files += Get-Item -LiteralPath $file
    }
    if (-not $validCandidate) { continue }

    $runtimeVersions = @($files | ForEach-Object { $_.VersionInfo.FileVersion } | Sort-Object -Unique)
    if ($runtimeVersions.Count -ne 1 -or $runtimeVersions[0] -notmatch '^14\.') {
      continue
    }
    return [pscustomobject]@{
      VisualStudioPath = [IO.Path]::GetFullPath($installationPath)
      Directory = [IO.Path]::GetFullPath($candidate.Directory)
      ToolsetVersion = $candidate.ToolsetVersion.ToString()
      RuntimeVersion = $runtimeVersions[0]
      Files = $files
    }
  }

  throw "No signed x64 Visual C++ runtime containing $($RequiredFiles -join ', ') was found"
}

function Find-DumpBin {
  param([Parameter(Mandatory = $true)][string]$VisualStudioPath)

  $toolsRoot = Join-Path $VisualStudioPath 'VC\Tools\MSVC'
  $candidates = Get-ChildItem -LiteralPath $toolsRoot -Filter dumpbin.exe -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '[\\/]Hostx64[\\/]x64[\\/]dumpbin\.exe$' } |
    Sort-Object FullName -Descending
  if (-not $candidates) { throw "dumpbin.exe was not found under: $toolsRoot" }
  return $candidates[0].FullName
}

function Assert-VisualCppDependencyClosure {
  param(
    [Parameter(Mandatory = $true)][string]$ReleaseRoot,
    [Parameter(Mandatory = $true)][string]$DumpBin
  )

  $release = [IO.Path]::GetFullPath($ReleaseRoot)
  $available = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  Get-ChildItem -LiteralPath $release -File -Recurse | ForEach-Object { $null = $available.Add($_.Name) }

  foreach ($binary in Get-ChildItem -LiteralPath $release -File -Recurse |
      Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.node') }) {
    $output = & $DumpBin /nologo /dependents $binary.FullName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for: $($binary.FullName)" }
    foreach ($line in $output) {
      if ($line -notmatch '^\s+((?:msvcp|vcruntime|concrt|vccorlib)\d[^\s]*\.dll)\s*$') { continue }
      $dependency = $Matches[1]
      if (-not $available.Contains($dependency)) {
        throw "Visual C++ dependency is not bundled: $dependency (required by $($binary.Name))"
      }
    }
  }
}
