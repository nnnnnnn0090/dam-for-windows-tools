# ステージングした配布物を検証します。build_release.ps1 から呼ばれます。
#   - 必須ファイルがそろっている / 想定外のファイルが無い（旧版DLLの混入など）
#   - SHA256SUMS.txt と全ファイルが一致し、記載漏れも無い
#   - BUILD_INFO.json の版数と、同梱物の版数・ハッシュ
#   - FFmpegがDAM互換のHLSを実際に生成できる
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Stage)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\common.ps1"

$config = Read-ReleaseConfig
$version = $config.releaseVersion
$overlayName = "dam_scoring_overlay_$($version.Replace('.', '_')).dll"

$required = @(
  'DAMforWindowsTools.exe', 'flutter_windows.dll', 'updater.exe', $overlayName,
  'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
  'data/app.so', 'data/icudtl.dat',
  'data/flutter_assets/AssetManifest.bin',
  'data/flutter_assets/assets/remote/index.html',
  'data/flutter_assets/assets/scoring/technique_43.png',
  'runtime/ffmpeg.exe', 'runtime/node.exe',
  'runtime/helper/main.js', 'runtime/helper/supported-dam.json',
  'runtime/helper/agent/70_rpc_exports.js',
  'runtime/helper/node_modules/frida/build/frida_binding.node',
  'README.md', 'LICENSE', 'LEGAL_NOTICE.md', 'THIRD_PARTY_NOTICES.md',
  'BUILD_INFO.json', 'SHA256SUMS.txt'
)
foreach ($relative in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $Stage $relative))) { throw "必須ファイルがありません: $relative" }
}

$files = Get-ReleaseManifest $Stage | ForEach-Object { $_.Substring(66) }
$allowedTop = '^(DAMforWindowsTools\.exe|flutter_windows\.dll|updater\.exe|' + [regex]::Escape($overlayName) +
  '|msvcp140\.dll|vcruntime140(_1)?\.dll|README\.md|LICENSE|LEGAL_NOTICE\.md|THIRD_PARTY_NOTICES\.md|BUILD_INFO\.json|(data|runtime|LICENSES)/.+)$'
foreach ($file in $files) {
  if ($file -notmatch $allowedTop) { throw "想定外のファイルが含まれています: $file" }
  if ($file -match '(^|/)DAMforWindowsToolsData/') { throw "利用者データが含まれています: $file" }
}

$expected = Get-Content (Join-Path $Stage 'SHA256SUMS.txt')
$actual = Get-ReleaseManifest $Stage
if (Compare-Object $expected $actual) { throw 'SHA256SUMS.txt と実ファイルが一致しません' }

$info = Get-Content -Raw -Encoding utf8 (Join-Path $Stage 'BUILD_INFO.json') | ConvertFrom-Json
if ($info.releaseVersion -ne $version) { throw 'BUILD_INFO.json の版数が違います' }
$exeVersion = (Get-Item (Join-Path $Stage 'DAMforWindowsTools.exe')).VersionInfo.ProductVersion
if (-not $exeVersion.StartsWith($version)) { throw "EXEの製品版 $exeVersion が $version と一致しません" }
$ffmpeg = Join-Path $Stage 'runtime/ffmpeg.exe'
if ((Get-Sha256 $ffmpeg) -ne $config.inputs.ffmpeg.executableSha256) { throw 'ffmpeg.exe のSHA-256が違います' }
$nodeVersion = (& (Join-Path $Stage 'runtime/node.exe') --version).Trim()
if ($nodeVersion -ne "v$($config.helper.nodeVersion)") { throw "同梱Node.jsの版が違います: $nodeVersion" }
$manifest = Get-Content -Raw -Encoding utf8 (Join-Path $Stage 'runtime/helper/supported-dam.json') | ConvertFrom-Json
if ($manifest.target.sha256 -ne $config.damTarget.sha256 -or $manifest.target.fileVersion -ne $config.damTarget.fileVersion) {
  throw 'supported-dam.json の対象DAMが release.json と一致しません'
}

# FFmpegでDAM互換HLS（libx264 + AAC）を実際に生成できるか確認します。
$probe = Join-Path ([IO.Path]::GetTempPath()) "dam-tools-verify-$PID"
New-Item -ItemType Directory -Force $probe | Out-Null
try {
  Invoke-Native 'FFmpeg HLS生成確認' {
    & $ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i sine=duration=3 `
      -c:v libx264 -profile:v baseline -pix_fmt yuv420p -c:a aac -f hls -hls_time 1 -hls_playlist_type event (Join-Path $probe 'index.m3u8')
  }
  if (-not (Select-String -Path (Join-Path $probe 'index.m3u8') -Pattern '#EXT-X-ENDLIST' -Quiet)) { throw 'FFmpegのHLS出力が不完全です' }
} finally { Remove-Item -Recurse -Force $probe }

Write-Host "配布物を検証しました ($($files.Count) ファイル)"
