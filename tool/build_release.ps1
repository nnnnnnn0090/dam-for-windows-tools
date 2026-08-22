# Project: DAM for Windows Tools
# File: build_release.ps1
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-22

[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [switch]$RequireSignature,
  [string]$CertificateThumbprint = $env:DAM_TOOLS_SIGN_CERT_THUMBPRINT,
  [string]$TimestampUrl = $(if ($env:DAM_TOOLS_TIMESTAMP_URL) { $env:DAM_TOOLS_TIMESTAMP_URL } else { 'http://timestamp.digicert.com' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'msvc_runtime.ps1')

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

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$releaseName = 'DAMforWindowsTools'
$releaseConfigPath = Join-Path $projectRoot 'tool\release_config.json'
$releaseConfig = Get-Content -LiteralPath $releaseConfigPath -Raw | ConvertFrom-Json
$releaseVersion = $releaseConfig.releaseVersion
$nodeVersion = $releaseConfig.nodeVersion
$fridaVersion = $releaseConfig.fridaVersion
$ffmpegVersion = $releaseConfig.ffmpegVersion
$ffmpegSourceCommit = $releaseConfig.ffmpegSourceCommit
$msvcRuntimeFiles = [string[]]@($releaseConfig.msvcRuntimeFiles)
if (-not $msvcRuntimeFiles -or $msvcRuntimeFiles.Count -eq 0 -or
    (@($msvcRuntimeFiles | Sort-Object -Unique)).Count -ne $msvcRuntimeFiles.Count) {
  throw 'release_config.json contains an invalid Visual C++ runtime file list'
}
$msvcRuntime = Find-VisualCppAppLocalRuntime -RequiredFiles $msvcRuntimeFiles
$dumpBin = Find-DumpBin -VisualStudioPath $msvcRuntime.VisualStudioPath
$pubspecText = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
if ($pubspecText -notmatch '(?m)^version:\s*([^+\s]+)') { throw 'pubspec.yaml version is missing' }
if ($Matches[1] -ne $releaseVersion) { throw 'pubspec.yaml and release_config.json versions differ' }
$sidecarPackage = Get-Content -LiteralPath (Join-Path $projectRoot 'sidecar\package.json') -Raw | ConvertFrom-Json
if ($sidecarPackage.engines.node -ne $nodeVersion -or $sidecarPackage.dependencies.frida -ne $fridaVersion) {
  throw 'sidecar/package.json and release_config.json versions differ'
}
$executableName = "$releaseName.exe"
$manifestName = 'supported-dam.json'
$distRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'dist'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build'))
$releasePackageRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot 'release_package'))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $releasePackageRoot $releaseName))
$sourcePackageRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot 'source_package'))
$sourceBundleName = "$releaseName-$releaseVersion-source"
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $sourcePackageRoot $sourceBundleName))
$rootPrefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$buildPrefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
foreach ($stagingPath in @($releasePackageRoot, $releaseRoot, $sourcePackageRoot, $sourceRoot)) {
  if (-not $stagingPath.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe staging path: $stagingPath"
  }
}

$nodeArchive = Join-Path $projectRoot "tool\cache\node-v$nodeVersion-win-x64.zip"
$nodeCache = Join-Path $projectRoot "tool\cache\node-v$nodeVersion-win-x64"
$ffmpegArchive = Join-Path $projectRoot "tool\cache\ffmpeg-$ffmpegVersion-full_build.zip"
$ffmpegBundle = Join-Path $projectRoot "tool\cache\ffmpeg-$ffmpegVersion-full_build\ffmpeg-$ffmpegVersion-full_build"
$ffmpegExe = Join-Path $ffmpegBundle 'bin\ffmpeg.exe'
$ffmpegLicense = Join-Path $ffmpegBundle 'LICENSE'
$ffmpegReadme = Join-Path $ffmpegBundle 'README.txt'
$ffmpegSource = Join-Path $projectRoot "tool\cache\FFmpeg-$ffmpegSourceCommit.tar.gz"
$nodeExe = Join-Path $nodeCache 'node.exe'
$nodeLicense = Join-Path $nodeCache 'LICENSE'
$sourceInputs = Join-Path $projectRoot 'tool\source_inputs.json'
foreach ($required in @($sourceInputs, $releaseConfigPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required release input is missing: $required"
  }
}

& (Join-Path $PSScriptRoot 'bootstrap_dependencies.ps1') `
  -ManifestPath $sourceInputs `
  -CacheRoot (Join-Path $projectRoot 'tool\cache')

$inputDefinition = Get-Content -LiteralPath $sourceInputs -Raw | ConvertFrom-Json
foreach ($required in @($nodeArchive, $ffmpegArchive, $ffmpegSource)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required pinned release input is missing: $required"
  }
}

if (-not (Test-Path -LiteralPath $nodeCache -PathType Container)) {
  Expand-Archive -LiteralPath $nodeArchive -DestinationPath (Split-Path -Parent $nodeCache)
}
foreach ($required in @($nodeExe, $nodeLicense)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required file is missing from the pinned Node.js distribution: $required"
  }
}

if (-not (Test-Path -LiteralPath $ffmpegBundle -PathType Container)) {
  $ffmpegExtractRoot = Split-Path -Parent $ffmpegBundle
  New-Item -ItemType Directory -Force -Path $ffmpegExtractRoot | Out-Null
  Expand-Archive -LiteralPath $ffmpegArchive -DestinationPath $ffmpegExtractRoot
}
foreach ($required in @($ffmpegExe, $ffmpegLicense, $ffmpegReadme)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required file is missing from the pinned FFmpeg distribution: $required"
  }
}

$ffmpegHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ffmpegExe).Hash.ToLowerInvariant()
if ($ffmpegHash -ne $releaseConfig.ffmpegExecutableSha256) {
  throw 'The extracted FFmpeg executable does not match the pinned release configuration'
}
$ffmpegVersionOutput = & $ffmpegExe -version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $ffmpegVersionOutput -notmatch "ffmpeg version $([regex]::Escape($ffmpegVersion))-full_build-www\.gyan\.dev") {
  throw 'Unexpected FFmpeg distribution or version'
}
$ffmpegEncoders = & $ffmpegExe -hide_banner -encoders 2>&1 | Out-String
$ffmpegMuxers = & $ffmpegExe -hide_banner -muxers 2>&1 | Out-String
if ($ffmpegEncoders -notmatch '(?m)^\s*V\S*\s+libx264\s' -or
    $ffmpegEncoders -notmatch '(?m)^\s*A\S*\s+aac\s' -or
    $ffmpegMuxers -notmatch '(?m)^\s*E\s+hls\s') {
  throw 'The pinned FFmpeg build does not provide the required H.264, AAC, and HLS features'
}

$repositoryState = & git -C $projectRoot status --porcelain --untracked-files=normal
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($repositoryState) {
  throw 'Release builds require a clean committed worktree'
}

Push-Location $projectRoot
try {
  if (-not $SkipBuild) {
    & (Join-Path $nodeCache 'npm.cmd') ci --omit=dev --prefix (Join-Path $projectRoot 'sidecar')
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
    & $nodeExe --check (Join-Path $projectRoot 'sidecar\main.js')
    if ($LASTEXITCODE -ne 0) { throw 'sidecar main syntax check failed' }
    & $nodeExe --check (Join-Path $projectRoot 'sidecar\target_config.js')
    if ($LASTEXITCODE -ne 0) { throw 'sidecar target config syntax check failed' }
    & $nodeExe --check (Join-Path $projectRoot 'sidecar\identity.js')
    if ($LASTEXITCODE -ne 0) { throw 'sidecar identity syntax check failed' }
    & $nodeExe --check (Join-Path $projectRoot 'sidecar\agent_source.js')
    if ($LASTEXITCODE -ne 0) { throw 'sidecar agent source syntax check failed' }
    & $nodeExe --check (Join-Path $projectRoot 'sidecar\agent.js')
    if ($LASTEXITCODE -ne 0) { throw 'sidecar agent syntax check failed' }
    & (Join-Path $nodeCache 'npm.cmd') test --prefix (Join-Path $projectRoot 'sidecar')
    if ($LASTEXITCODE -ne 0) { throw 'sidecar tests failed' }
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    & flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed' }
    & flutter test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter release build failed' }
  }

  foreach ($stagingRoot in @($releasePackageRoot, $sourcePackageRoot)) {
    if (Test-Path -LiteralPath $stagingRoot) {
      $resolved = [IO.Path]::GetFullPath($stagingRoot)
      if (-not $resolved.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unsafe staging path: $resolved"
      }
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  }
  New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $releaseRoot,$sourceRoot | Out-Null

  $flutterRelease = Join-Path $projectRoot 'build\windows\x64\runner\Release'
  if (-not (Test-Path -LiteralPath (Join-Path $flutterRelease $executableName))) {
    throw "Flutter release output is missing: $flutterRelease"
  }
  Copy-Item -Path (Join-Path $flutterRelease '*') -Destination $releaseRoot -Recurse -Force

  $microsoftRuntimeDestinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($runtimeFile in $msvcRuntime.Files) {
    $destination = Join-Path $releaseRoot $runtimeFile.Name
    Copy-Item -LiteralPath $runtimeFile.FullName -Destination $destination
    Assert-MicrosoftSignedFile -Path $destination
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimeFile.FullName).Hash
    $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
    if ($sourceHash -ne $destinationHash) {
      throw "Visual C++ runtime changed while copying: $($runtimeFile.Name)"
    }
    $null = $microsoftRuntimeDestinations.Add([IO.Path]::GetFullPath($destination))
  }

  $runtime = Join-Path $releaseRoot 'runtime'
  $helper = Join-Path $runtime 'helper'
  New-Item -ItemType Directory -Force -Path $helper | Out-Null
  Copy-Item -LiteralPath $nodeExe -Destination (Join-Path $runtime 'node.exe')
  Copy-Item -LiteralPath $ffmpegExe -Destination (Join-Path $runtime 'ffmpeg.exe')
  Copy-Item -LiteralPath (Join-Path $projectRoot 'sidecar\main.js') -Destination $helper
  Copy-Item -LiteralPath (Join-Path $projectRoot 'sidecar\target_config.js') -Destination $helper
  Copy-Item -LiteralPath (Join-Path $projectRoot 'sidecar\identity.js') -Destination $helper
  Copy-Item -LiteralPath (Join-Path $projectRoot 'sidecar\agent_source.js') -Destination $helper
  Copy-Item -LiteralPath (Join-Path $projectRoot 'sidecar\agent.js') -Destination $helper
  Copy-Item -LiteralPath (Join-Path $projectRoot 'sidecar\package.json') -Destination $helper
  Copy-Item -LiteralPath (Join-Path $projectRoot "sidecar\$manifestName") -Destination $helper

  $sourceModules = Join-Path $projectRoot 'sidecar\node_modules'
  $runtimeModules = Join-Path $helper 'node_modules'
  New-Item -ItemType Directory -Force -Path $runtimeModules | Out-Null
  Copy-RuntimePackage -SourceModules $sourceModules -DestinationModules $runtimeModules -PackageName 'frida' -Entries @(
    'package.json',
    'build\frida_binding.node',
    'build\src\frida.js'
  )
  Copy-RuntimePackage -SourceModules $sourceModules -DestinationModules $runtimeModules -PackageName 'bindings' -Entries @(
    'package.json',
    'bindings.js'
  )
  Copy-RuntimePackage -SourceModules $sourceModules -DestinationModules $runtimeModules -PackageName 'file-uri-to-path' -Entries @(
    'package.json',
    'index.js'
  )
  foreach ($package in @('minimatch','brace-expansion','balanced-match')) {
    Copy-RuntimePackage -SourceModules $sourceModules -DestinationModules $runtimeModules -PackageName $package -Entries @(
      'package.json',
      'dist\esm'
    )
  }

  foreach ($file in @('README.md','LICENSE','THIRD_PARTY_NOTICES.md','LEGAL_NOTICE.md')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $file) -Destination $releaseRoot
  }
  $releaseImages = Join-Path $releaseRoot 'docs\images'
  New-Item -ItemType Directory -Force -Path $releaseImages | Out-Null
  Copy-Item -Path (Join-Path $projectRoot 'docs\images\*') -Destination $releaseImages
  $licenses = Join-Path $releaseRoot 'LICENSES'
  $npmLicenses = Join-Path $licenses 'npm'
  New-Item -ItemType Directory -Force -Path $npmLicenses | Out-Null
  Copy-Item -LiteralPath $nodeLicense -Destination (Join-Path $licenses "Node.js-$nodeVersion.txt")
  Copy-Item -LiteralPath $ffmpegLicense -Destination (Join-Path $licenses 'FFmpeg-Gyan-GPLv3.txt')
  Copy-Item -LiteralPath $ffmpegReadme -Destination (Join-Path $licenses 'FFmpeg-Gyan-README.txt')
  Copy-Item -LiteralPath (Join-Path $projectRoot 'legal\Frida-LGPL-2.0.txt') -Destination $licenses
  Copy-Item -LiteralPath (Join-Path $projectRoot 'legal\Microsoft-Visual-Cpp-Runtime.txt') -Destination $licenses
  Copy-Item -LiteralPath (Join-Path $projectRoot 'legal\WxWindows-exception-3.1.txt') -Destination $licenses
  Copy-Item -LiteralPath (Join-Path $projectRoot 'legal\QR-Code-generator-MIT.txt') -Destination $licenses

  foreach ($package in @('bindings','file-uri-to-path','minimatch','brace-expansion','balanced-match')) {
    Get-ChildItem -LiteralPath (Join-Path $sourceModules $package) -File |
      Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING)(\..*)?$' } |
      ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $npmLicenses "$package--$($_.Name)")
      }
  }

  Copy-Item -LiteralPath $ffmpegSource -Destination $sourceRoot
  Copy-Item -LiteralPath $sourceInputs -Destination $sourceRoot
  Copy-Item -LiteralPath $releaseConfigPath -Destination $sourceRoot
  Copy-Item -LiteralPath (Join-Path $projectRoot 'legal\FRIDA_SOURCE.txt') -Destination $sourceRoot
  foreach ($fridaSourceName in @(
    "frida-$fridaVersion.tar.gz",
    "frida-node-$fridaVersion.tar.gz",
    "frida-core-$fridaVersion.tar.gz",
    "frida-gum-$fridaVersion.tar.gz"
  )) {
    Copy-Item -LiteralPath (Join-Path $projectRoot "tool\cache\$fridaSourceName") -Destination $sourceRoot
  }

  $projectSource = Join-Path $sourceRoot "$releaseName-$releaseVersion-project-source.zip"
  & git -C $projectRoot archive --format=zip --output=$projectSource HEAD
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $projectSource)) {
    throw 'Project source archive generation failed'
  }

  $ffmpegConfig = & $ffmpegExe -version 2>&1 | Out-String
  [IO.File]::WriteAllText((Join-Path $licenses 'FFmpeg-Gyan-build.txt'), $ffmpegConfig, [Text.UTF8Encoding]::new($false))

  Push-Location $helper
  try {
    & (Join-Path $runtime 'node.exe') --input-type=module --eval "import('frida').then((module) => { if (typeof module.attach !== 'function') process.exit(1); })"
    if ($LASTEXITCODE -ne 0) { throw 'Pruned Frida runtime import test failed' }
  } finally {
    Pop-Location
  }

  $nodeSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $runtime 'node.exe')
  if ($nodeSignature.Status -ne 'Valid') {
    throw "The upstream Node.js signature is invalid: $($nodeSignature.Status)"
  }
  Assert-VisualCppDependencyClosure -ReleaseRoot $releaseRoot -DumpBin $dumpBin
  if ($CertificateThumbprint) {
    $signTool = Find-SignTool
    if (-not $signTool) { throw 'signtool.exe was not found' }
    $signTargets = Get-ChildItem -LiteralPath $releaseRoot -Recurse -File |
      Where-Object {
        $_.FullName -ne (Join-Path $runtime 'node.exe') -and
        -not $microsoftRuntimeDestinations.Contains([IO.Path]::GetFullPath($_.FullName)) -and
        $_.Extension.ToLowerInvariant() -in @('.exe', '.dll', '.node')
      } |
      Select-Object -ExpandProperty FullName
    Invoke-CodeSign -SignTool $signTool -Thumbprint $CertificateThumbprint -Files $signTargets -Rfc3161Url $TimestampUrl
  } elseif ($RequireSignature) {
    throw 'A trusted code-signing certificate is required. Set DAM_TOOLS_SIGN_CERT_THUMBPRINT.'
  } else {
    Write-Warning 'Unsigned development release. Formal public releases must use -RequireSignature.'
  }

  $gitCommit = (& git -C $projectRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $gitCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Unable to determine the release commit'
  }
  $targetManifest = Get-Content -LiteralPath (Join-Path $projectRoot "sidecar\$manifestName") -Raw | ConvertFrom-Json
  $buildInfo = [ordered]@{
    _meta = [ordered]@{
      project = 'DAM for Windows Tools'
      file = 'BUILD_INFO.json'
      copyright = 'Copyright (c) 2026 nnnnnnn0090. All rights reserved.'
      license = 'GPL-3.0-or-later'
      created = '2026-08-22'
    }
    schemaVersion = 1
    releaseVersion = $releaseVersion
    sourceCommit = $gitCommit
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    signed = [bool]$CertificateThumbprint
    sourceBundle = "$sourceBundleName.zip"
    runtimes = [ordered]@{
      flutter = $releaseConfig.flutterVersion
      dart = $releaseConfig.dartVersion
      node = $nodeVersion
      frida = $fridaVersion
      ffmpeg = $ffmpegVersion
      ffmpegDistribution = $releaseConfig.ffmpegDistribution
      ffmpegSourceCommit = $ffmpegSourceCommit
      msvc = [ordered]@{
        deployment = 'app-local'
        runtimeVersion = $msvcRuntime.RuntimeVersion
        toolsetVersion = $msvcRuntime.ToolsetVersion
        files = @($msvcRuntimeFiles | ForEach-Object {
          $runtimePath = Join-Path $releaseRoot $_
          [ordered]@{
            name = $_
            version = (Get-Item -LiteralPath $runtimePath).VersionInfo.FileVersion
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimePath).Hash.ToLowerInvariant()
          }
        })
      }
    }
    target = [ordered]@{
      processName = $targetManifest.target.processName
      fileVersion = $targetManifest.target.fileVersion
      sha256 = $targetManifest.target.sha256
    }
  }
  [IO.File]::WriteAllText(
    (Join-Path $releaseRoot 'BUILD_INFO.json'),
    ($buildInfo | ConvertTo-Json -Depth 6),
    [Text.UTF8Encoding]::new($false)
  )

  $forbiddenData = Join-Path $releaseRoot 'DAMforWindowsToolsData'
  if (Test-Path -LiteralPath $forbiddenData) {
    throw 'Runtime data must never be included in the release package'
  }

  $hashFile = Join-Path $releaseRoot 'SHA256SUMS.txt'
  $hashLines = Get-ChildItem -LiteralPath $releaseRoot -Recurse -File |
    Where-Object { $_.FullName -ne $hashFile } |
    Sort-Object FullName |
    ForEach-Object {
      $relative = (Get-RelativePathCompat -BasePath $releaseRoot -TargetPath $_.FullName).Replace('\','/')
      $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
      "$hash  $relative"
    }
  [IO.File]::WriteAllLines($hashFile, $hashLines, [Text.UTF8Encoding]::new($false))

  & (Join-Path $projectRoot 'tool\verify_release.ps1') -ReleaseRoot $releaseRoot -RequireSignature:$RequireSignature
  if ($LASTEXITCODE -ne 0) { throw 'Release verification failed' }

  $zip = Join-Path $distRoot "$releaseName-$releaseVersion-win-x64.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -LiteralPath $releaseRoot -DestinationPath $zip -CompressionLevel Optimal
  $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
  $zipHashFile = "$zip.sha256"
  [IO.File]::WriteAllText(
    $zipHashFile,
    "$zipHash  $(Split-Path -Leaf $zip)`n",
    [Text.UTF8Encoding]::new($false)
  )
  $sourceZip = Join-Path $distRoot "$sourceBundleName.zip"
  if (Test-Path -LiteralPath $sourceZip) { Remove-Item -LiteralPath $sourceZip -Force }
  Compress-Archive -LiteralPath $sourceRoot -DestinationPath $sourceZip -CompressionLevel Optimal
  $sourceZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceZip).Hash.ToLowerInvariant()
  $sourceZipHashFile = "$sourceZip.sha256"
  [IO.File]::WriteAllText(
    $sourceZipHashFile,
    "$sourceZipHash  $(Split-Path -Leaf $sourceZip)`n",
    [Text.UTF8Encoding]::new($false)
  )
  Write-Host "Release ZIP:    $zip"
  Write-Host "ZIP checksum:   $zipHashFile"
  Write-Host "Source ZIP:     $sourceZip"
  Write-Host "Source checksum:$sourceZipHashFile"
  Get-FileHash -Algorithm SHA256 -LiteralPath $zip
} finally {
  Pop-Location
  foreach ($stagingRoot in @($releasePackageRoot, $sourcePackageRoot)) {
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) {
      $resolved = [IO.Path]::GetFullPath($stagingRoot)
      if ($resolved.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
      }
    }
  }
}
