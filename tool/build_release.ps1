# 配布用ZIPを作ります。
#
#   1. 版数・ツールチェーンの一致確認、作業ツリーがクリーンか確認
#   2. 依存物の取得と検証（tool/bootstrap.ps1）
#   3. 静的解析と試験（Dart / helper / Rust）
#   4. Flutter と Rust のリリースビルド
#   5. 同梱ファイルを明示的に列挙してステージングへ集める（余計なファイルは入れない）
#   6. BUILD_INFO.json と SHA256SUMS.txt を作り、tool/verify_release.ps1 で検証
#   7. dist/ へ ZIP・ZIPのSHA-256（.sha256）・ソースZIPを出力
#
#   -AllowDirty  未コミットの変更があっても続行します（試験用。配布には使わない）。
#   -SkipTests   試験を省略します（試験用。配布には使わない）。
[CmdletBinding()]
param([switch]$AllowDirty, [switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
. "$PSScriptRoot\common.ps1"

$repo = Split-Path $PSScriptRoot
$config = Read-ReleaseConfig
$version = $config.releaseVersion
$cache = Join-Path $PSScriptRoot 'cache'
$dist = Join-Path $repo 'dist'
$stageRoot = Join-Path $dist 'stage'
$stage = Join-Path $stageRoot $config.productName
$overlayName = "dam_scoring_overlay_$($version.Replace('.', '_')).dll"

Set-Location $repo

# ---- 1. 一致確認 ----
$pubspecVersion = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)\+').Matches[0].Groups[1].Value
$appVersion = (Select-String -Path lib/app_config.dart -Pattern "productVersion = '([0-9.]+)'").Matches[0].Groups[1].Value
$cargoVersion = (Select-String -Path native/Cargo.toml -Pattern '^version = "([0-9.]+)"').Matches[0].Groups[1].Value
foreach ($pair in @(@('pubspec.yaml', $pubspecVersion), @('lib/app_config.dart', $appVersion), @('native/Cargo.toml', $cargoVersion))) {
  if ($pair[1] -ne $version) { throw "$($pair[0]) の版 $($pair[1]) が release.json の $version と一致しません" }
}
$flutterVersion = ((& flutter --version --machine | Out-String) | ConvertFrom-Json).frameworkVersion
if ($flutterVersion -ne $config.toolchain.flutter) {
  throw "Flutter $flutterVersion ではなく $($config.toolchain.flutter) を使ってください"
}
$rustVersion = (& rustc --version).Split(' ')[1]
if (-not $rustVersion.StartsWith($config.toolchain.rust)) {
  throw "Rust $rustVersion ではなく $($config.toolchain.rust) を使ってください"
}
$commit = (& git rev-parse --verify --quiet HEAD) -as [string]
if (-not $AllowDirty) {
  if (-not $commit) { throw 'コミットがありません' }
  if (& git status --porcelain) { throw '未コミットの変更があります' }
}
if (-not $commit) { $commit = 'uncommitted' }

# ---- 2. 依存物 ----
& "$PSScriptRoot\bootstrap.ps1" -Sources
$node = Join-Path $cache 'node\node.exe'

# ---- 3. 試験 ----
if (-not $SkipTests) {
  Invoke-Native 'dart analyze' { dart analyze --fatal-infos }
  Invoke-Native 'flutter test' { flutter test }
  Push-Location helper
  try {
    foreach ($file in Get-ChildItem *.js) { Invoke-Native "node --check $($file.Name)" { & $node --check $file.FullName } }
    Invoke-Native 'Agent構文検査' { & $node check_agent_syntax.js }
    Invoke-Native 'helper試験' { & $node --test }
  } finally { Pop-Location }
  Push-Location native
  try {
    Invoke-Native 'cargo clippy' { cargo clippy --release --workspace --all-targets -- -D warnings }
    Invoke-Native 'cargo test' { cargo test --release --workspace }
  } finally { Pop-Location }
}

# ---- 4. ビルド ----
Invoke-Native 'flutter build' { flutter build windows --release }
Push-Location native
try { Invoke-Native 'cargo build' { cargo build --release --workspace } } finally { Pop-Location }
$flutterOut = Join-Path $repo 'build\windows\x64\runner\Release'
$nativeOut = Join-Path $repo 'native\target\release'

# ---- 5. ステージング ----
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Force $stage | Out-Null

function Copy-Into([string]$Source, [string]$RelativeDestination) {
  if (-not (Test-Path -LiteralPath $Source)) { throw "同梱するファイルがありません: $Source" }
  $destination = Join-Path $stage $RelativeDestination
  New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination -Recurse -Force
}

Copy-Into (Join-Path $flutterOut 'DAMforWindowsTools.exe') 'DAMforWindowsTools.exe'
Copy-Into (Join-Path $flutterOut 'flutter_windows.dll') 'flutter_windows.dll'
Copy-Into (Join-Path $flutterOut 'data') 'data'
Copy-Into (Join-Path $nativeOut 'updater.exe') 'updater.exe'
Copy-Into (Join-Path $nativeOut 'scoring_overlay.dll') $overlayName

# Flutter本体が使うMSVCランタイム（Microsoft署名を確認してから同梱）
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
foreach ($name in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  $file = Join-Path $crt.FullName $name
  $signature = Get-AuthenticodeSignature $file
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "$name のMicrosoft署名を確認できません"
  }
  Copy-Into $file $name
}

# runtime: FFmpeg・Node.js・接続ヘルパー
Copy-Into (Join-Path $cache 'ffmpeg\ffmpeg.exe') 'runtime\ffmpeg.exe'
Copy-Into $node 'runtime\node.exe'
foreach ($file in Get-ChildItem helper -File | Where-Object { $_.Extension -in '.js', '.json' -and $_.Name -ne 'package-lock.json' -and $_.Name -ne 'check_agent_syntax.js' }) {
  Copy-Into $file.FullName "runtime\helper\$($file.Name)"
}
Copy-Into (Join-Path $repo 'helper\agent') 'runtime\helper\agent'
foreach ($package in $config.helper.runtimePackages) {
  $source = Join-Path $repo "helper\node_modules\$package"
  if ($package -eq 'frida') {
    # 197MBのうち実行に必要なのはバインディングとJSだけです。
    foreach ($relative in 'package.json', 'COPYING', 'build\frida_binding.node', 'build\src\frida.js') {
      if (Test-Path (Join-Path $source $relative)) { Copy-Into (Join-Path $source $relative) "runtime\helper\node_modules\frida\$relative" }
    }
  } else {
    Copy-Into $source "runtime\helper\node_modules\$package"
  }
}
Push-Location (Join-Path $stage 'runtime\helper')
try {
  Invoke-Native '同梱fridaの読み込み確認' { & (Join-Path $stage 'runtime\node.exe') --input-type=module -e "await import('frida'); console.log('frida ok')" }
} finally { Pop-Location }

# 文書・ライセンス
foreach ($name in 'README.md', 'LICENSE', 'LEGAL_NOTICE.md', 'THIRD_PARTY_NOTICES.md') { Copy-Into $name $name }
foreach ($file in Get-ChildItem legal -File) { Copy-Into $file.FullName "LICENSES\$($file.Name)" }
Copy-Into (Join-Path $cache 'ffmpeg\ffmpeg-README.txt') 'LICENSES\FFmpeg-build-README.txt'
Copy-Into (Join-Path $cache 'node\LICENSE') 'LICENSES\Node.js-LICENSE.txt'

# ---- 6. ビルド情報・検証 ----
[ordered]@{
  schemaVersion  = 2
  releaseVersion = $version
  commit         = $commit
  builtAtUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  flutter        = $flutterVersion
  rust           = $rustVersion
  node           = $config.helper.nodeVersion
  frida          = $config.helper.fridaVersion
  ffmpeg         = $config.inputs.ffmpeg.version
  damTarget      = $config.damTarget
} | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $stage 'BUILD_INFO.json')
Get-ReleaseManifest $stage | Set-Content -Encoding ascii (Join-Path $stage 'SHA256SUMS.txt')
& "$PSScriptRoot\verify_release.ps1" -Stage $stage

# ---- 7. 出力 ----
New-Item -ItemType Directory -Force $dist | Out-Null
$zipName = "$($config.productName)-$version-win-x64.zip"
$zip = Join-Path $dist $zipName
Remove-Item -Force -ErrorAction SilentlyContinue $zip, "$zip.sha256"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  $stageFull = [IO.Path]::GetFullPath($stageRoot).TrimEnd('\') + '\'
  foreach ($file in Get-ChildItem $stage -Recurse -File) {
    $entry = $file.FullName.Substring($stageFull.Length).Replace('\', '/')
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, 'Optimal') | Out-Null
  }
} finally { $archive.Dispose() }
[IO.File]::WriteAllText("$zip.sha256", "$(Get-Sha256 $zip)  $zipName`n", [Text.Encoding]::ASCII)

$sourceZip = Join-Path $dist "$($config.productName)-$version-source.zip"
Remove-Item -Force -ErrorAction SilentlyContinue $sourceZip
$sourceStage = Join-Path $dist 'source'
if (Test-Path $sourceStage) { Remove-Item -Recurse -Force $sourceStage }
New-Item -ItemType Directory -Force $sourceStage | Out-Null
if ($commit -ne 'uncommitted') {
  Invoke-Native 'git archive' { git archive --format=zip -o (Join-Path $sourceStage "$($config.productName)-$version-project-source.zip") HEAD }
} else {
  Write-Warning 'コミットが無いため、本体ソースはソースZIPに含めていません（配布には使わないでください）'
}
foreach ($item in $config.correspondingSources) { Copy-Item (Join-Path $cache $item.file) $sourceStage }
Copy-Item tool/release.json $sourceStage
Compress-Archive -Path "$sourceStage\*" -DestinationPath $sourceZip
Remove-Item -Recurse -Force $sourceStage, $stageRoot

Write-Host "作成しました: $zip"
Write-Host "             $zip.sha256"
Write-Host "             $sourceZip"
