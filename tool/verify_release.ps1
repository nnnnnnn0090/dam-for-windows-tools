# Project: DAM for Windows Tools
# File: verify_release.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-22

# 配布フォルダの必須物・禁止物・ハッシュ・署名・外部依存閉包をリリース前に検証します。

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ReleaseRoot,
  [switch]$RequireSignature
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'msvc_runtime.ps1')

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$release = [IO.Path]::GetFullPath($ReleaseRoot)
if (-not (Test-Path -LiteralPath $release -PathType Container)) {
  throw "Release folder does not exist: $release"
}
$releaseConfig = Get-Content -LiteralPath (Join-Path $projectRoot 'tool\release_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$requiredFiles = @(
  'DAMforWindowsTools.exe',
  'README.md',
  'LICENSE',
  'LEGAL_NOTICE.md',
  'THIRD_PARTY_NOTICES.md',
  'docs\images\app-main.png',
  'docs\images\remote-playback-control.jpg',
  'docs\images\remote-search.jpg',
  'docs\images\remote-song-detail.jpg',
  'docs\images\video-replacement-result.png',
  'SHA256SUMS.txt',
  'BUILD_INFO.json',
  'LICENSES\FFmpeg-Gyan-build.txt',
  'LICENSES\FFmpeg-Gyan-README.txt',
  'LICENSES\Lucide-ISC.txt',
  'LICENSES\Microsoft-Visual-Cpp-Runtime.txt',
  'runtime\node.exe',
  'runtime\ffmpeg.exe',
  'runtime\helper\main.js',
  'runtime\helper\agent_session.js',
  'runtime\helper\agent_source.js',
  'runtime\helper\command_router.js',
  'runtime\helper\helper_config.js',
  'runtime\helper\helper_protocol.js',
  'runtime\helper\identity.js',
  'runtime\helper\package.json',
  'runtime\helper\target_config.js',
  'runtime\helper\target_discovery.js',
  'runtime\helper\agent\00_runtime.js',
  'runtime\helper\agent\10_playback.js',
  'runtime\helper\agent\20_remote_playback.js',
  'runtime\helper\agent\30_scoring.js',
  'runtime\helper\agent\40_remote_requests.js',
  'runtime\helper\agent\50_remote_hooks.js',
  'runtime\helper\agent\60_validation.js',
  'runtime\helper\agent\70_rpc_exports.js',
  'runtime\helper\supported-dam.json'
)
$msvcRuntimeFiles = [string[]]@($releaseConfig.msvcRuntimeFiles)
$requiredFiles += $msvcRuntimeFiles
foreach ($relative in $requiredFiles) {
  $path = Join-Path $release $relative
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required release file is missing: $relative"
  }
}

foreach ($forbidden in @(
  'DAMforWindowsToolsData',
  'SOURCE',
  'CHANGELOG.md',
  'CONTRIBUTING.md',
  'RELEASING.md',
  'SECURITY.md',
  'release_config.json',
  'runtime\helper\package-lock.json'
)) {
  if (Test-Path -LiteralPath (Join-Path $release $forbidden)) {
    throw "Developer or runtime-generated content leaked into the user package: $forbidden"
  }
}

$hashFile = Join-Path $release 'SHA256SUMS.txt'
$listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in Get-Content -LiteralPath $hashFile) {
  if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Malformed checksum line: $line" }
  $expected = $Matches[1]
  $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
  $target = [IO.Path]::GetFullPath((Join-Path $release $relative))
  $prefix = $release.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Checksum path escapes the release folder: $relative"
  }
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Checksummed file is missing: $relative" }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
  if ($actual -ne $expected) { throw "Checksum mismatch: $relative" }
  if (-not $listed.Add($relative)) { throw "Duplicate checksum entry: $relative" }
}

$unlisted = Get-ChildItem -LiteralPath $release -Recurse -File |
  Where-Object { $_.FullName -ne $hashFile } |
  Where-Object {
    $relative = $_.FullName.Substring($release.Length + 1)
    -not $listed.Contains($relative)
  }
if ($unlisted) { throw "Unlisted release file: $($unlisted[0].FullName)" }

$node = Join-Path $release 'runtime\node.exe'
$nodeVersion = (& $node --version).Trim()
if ($LASTEXITCODE -ne 0 -or $nodeVersion -ne "v$($releaseConfig.nodeVersion)") {
  throw "Unexpected Node.js runtime: $nodeVersion"
}
$nodeSignature = Get-AuthenticodeSignature -LiteralPath $node
if ($nodeSignature.Status -ne 'Valid') {
  throw "Invalid upstream Node.js signature: $($nodeSignature.Status)"
}
$sidecarSources = @(
  'main.js','agent_session.js','agent_source.js','command_router.js',
  'helper_config.js','helper_protocol.js','identity.js','target_config.js','target_discovery.js',
  'agent\00_runtime.js','agent\10_playback.js','agent\20_remote_playback.js',
  'agent\30_scoring.js','agent\40_remote_requests.js','agent\50_remote_hooks.js',
  'agent\60_validation.js','agent\70_rpc_exports.js'
)
foreach ($sidecarSource in $sidecarSources) {
  & $node --check (Join-Path $release "runtime\helper\$sidecarSource")
  if ($LASTEXITCODE -ne 0) { throw "Packaged sidecar syntax check failed: $sidecarSource" }
}

$buildInfo = Get-Content -LiteralPath (Join-Path $release 'BUILD_INFO.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$unexpectedMsvcRuntime = Get-ChildItem -LiteralPath $release -File |
  Where-Object { $_.Name -match '^(?:msvcp|vcruntime|concrt|vccorlib)\d.*\.dll$' -and $_.Name -notin $msvcRuntimeFiles } |
  Select-Object -First 1
if ($unexpectedMsvcRuntime) {
  throw "Unexpected Visual C++ runtime file: $($unexpectedMsvcRuntime.Name)"
}
if ($buildInfo.runtimes.msvc.deployment -ne 'app-local') {
  throw 'Invalid Visual C++ runtime deployment metadata'
}
foreach ($fileName in $msvcRuntimeFiles) {
  $runtimePath = Join-Path $release $fileName
  Assert-MicrosoftSignedFile -Path $runtimePath
  $metadata = @($buildInfo.runtimes.msvc.files | Where-Object { $_.name -eq $fileName })
  if ($metadata.Count -ne 1) { throw "Visual C++ runtime metadata is missing or duplicated: $fileName" }
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimePath).Hash.ToLowerInvariant()
  $actualVersion = (Get-Item -LiteralPath $runtimePath).VersionInfo.FileVersion
  if ($metadata[0].sha256 -ne $actualHash -or $metadata[0].version -ne $actualVersion) {
    throw "Visual C++ runtime provenance mismatch: $fileName"
  }
}
$ffmpegConfiguration = Get-Content -LiteralPath (Join-Path $release 'LICENSES\FFmpeg-Gyan-build.txt') -Raw -Encoding UTF8
$ffmpeg = Join-Path $release 'runtime\ffmpeg.exe'
$ffmpegHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ffmpeg).Hash.ToLowerInvariant()
if (($buildInfo.signed -ne $true -and $ffmpegHash -ne $releaseConfig.ffmpegExecutableSha256) -or
    $ffmpegConfiguration -notmatch "ffmpeg version $([regex]::Escape($releaseConfig.ffmpegVersion))-full_build-www\.gyan\.dev" -or
    $ffmpegConfiguration -notmatch '--enable-gpl' -or
    $ffmpegConfiguration -notmatch '--enable-libx264' -or
    $ffmpegConfiguration -notmatch '--enable-static' -or
    $ffmpegConfiguration -match '--disable-everything') {
  throw 'Unexpected FFmpeg full-build binary or configuration'
}

$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ("dam-tools-ffmpeg-" + [Guid]::NewGuid().ToString('N'))
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$smokeRoot = [IO.Path]::GetFullPath($smokeRoot)
if (-not $smokeRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Unsafe FFmpeg smoke-test path: $smokeRoot"
}
New-Item -ItemType Directory -Path $smokeRoot | Out-Null
try {
  & $ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=25:duration=2' `
    -f lavfi -i 'sine=frequency=1000:duration=2' -c:v libx264 -profile:v baseline -pix_fmt yuv420p `
    -c:a aac -f hls -hls_time 1 -hls_list_size 0 -hls_segment_filename (Join-Path $smokeRoot 'segment-%03d.ts') `
    (Join-Path $smokeRoot 'index.m3u8')
  if ($LASTEXITCODE -ne 0 -or
      -not (Test-Path -LiteralPath (Join-Path $smokeRoot 'index.m3u8') -PathType Leaf) -or
      -not (Get-ChildItem -LiteralPath $smokeRoot -Filter '*.ts' -File)) {
    throw 'FFmpeg H.264/AAC/HLS smoke test failed'
  }
} finally {
  if (Test-Path -LiteralPath $smokeRoot) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
  }
}

$fridaPackage = Get-Content -LiteralPath (Join-Path $release 'runtime\helper\node_modules\frida\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($fridaPackage.version -ne $releaseConfig.fridaVersion) { throw "Unexpected Frida version: $($fridaPackage.version)" }
$expectedRuntimePackages = [Collections.Generic.HashSet[string]]::new(
  [string[]]@('frida','bindings','file-uri-to-path','minimatch','brace-expansion','balanced-match'),
  [StringComparer]::OrdinalIgnoreCase
)
$unexpectedRuntimePackage = Get-ChildItem -LiteralPath (Join-Path $release 'runtime\helper\node_modules') -Directory |
  Where-Object { -not $expectedRuntimePackages.Contains($_.Name) } |
  Select-Object -First 1
if ($unexpectedRuntimePackage) {
  throw "Unexpected install-time Node package in runtime: $($unexpectedRuntimePackage.Name)"
}
Push-Location (Join-Path $release 'runtime\helper')
try {
  & $node --input-type=module --eval "import('frida').then((module) => { if (typeof module.attach !== 'function') process.exit(1); })"
  if ($LASTEXITCODE -ne 0) { throw 'Packaged Frida runtime import test failed' }
} finally {
  Pop-Location
}

if ($buildInfo.releaseVersion -ne $releaseConfig.releaseVersion -or
    $buildInfo.sourceCommit -notmatch '^[0-9a-f]{40}$' -or
    $buildInfo.runtimes.node -ne $releaseConfig.nodeVersion -or
    $buildInfo.runtimes.frida -ne $releaseConfig.fridaVersion -or
    $buildInfo.runtimes.ffmpeg -ne $releaseConfig.ffmpegVersion -or
    $buildInfo.runtimes.ffmpegSourceCommit -ne $releaseConfig.ffmpegSourceCommit) {
  throw 'Invalid build provenance metadata'
}
if ($RequireSignature -and $buildInfo.signed -ne $true) {
  throw 'Build provenance marks this release as unsigned'
}

$target = Get-Content -LiteralPath (Join-Path $release 'runtime\helper\supported-dam.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($target.target.fileVersion -ne '1.1.7.0' -or
    $target.target.sha256 -ne 'c47e25af4d5b96d299c17dfcce464b5e84c5cce0f81b3080ce7e5beb37839099') {
  throw 'Unexpected DAM target identity'
}

if ($RequireSignature) {
  $unsigned = Get-ChildItem -LiteralPath $release -Recurse -File |
    Where-Object { $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.node') } |
    Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -ne 'Valid' }
  if ($unsigned) { throw "Unsigned release binary: $($unsigned[0].FullName)" }
}

Write-Host "Release verification passed: $release"
