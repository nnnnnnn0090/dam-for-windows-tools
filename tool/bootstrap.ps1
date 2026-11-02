# tool/release.json に固定した第三者の入力物を tool/cache へ取得し、SHA-256を検証して
# ビルドに必要なものを展開します。続けて helper/ の npm 依存を用意します。
#   -Sources       対応ソースの書庫も取得します（配布ビルドで必要）。
#   -FridaDevkit   Rust版 dam-link 用の frida-core devkit も取得します（未使用なら不要）。
[CmdletBinding()]
param([switch]$Sources, [switch]$FridaDevkit)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
. "$PSScriptRoot\common.ps1"

$config = Read-ReleaseConfig
$cache = Join-Path $PSScriptRoot 'cache'
New-Item -ItemType Directory -Force $cache | Out-Null
if ($PSVersionTable.PSVersion.Major -lt 6) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Get-VerifiedFile([pscustomobject]$Item) {
  if ($Item.file -notmatch '^[A-Za-z0-9._-]+$') { throw "不正なファイル名です: $($Item.file)" }
  if (-not $Item.url.StartsWith('https://')) { throw "HTTPS以外の取得元です: $($Item.url)" }
  $target = Join-Path $cache $Item.file
  if ((Test-Path $target) -and (Get-Sha256 $target) -eq $Item.sha256) { return $target }
  if (Test-Path $target) { Remove-Item -Force $target }

  $partial = "$target.part"
  for ($attempt = 1; ; $attempt++) {
    try {
      Write-Host "取得中: $($Item.file)"
      Invoke-WebRequest -Uri $Item.url -OutFile $partial -UseBasicParsing -TimeoutSec 900
      $actual = Get-Sha256 $partial
      if ($actual -ne $Item.sha256) { throw "$($Item.file) のSHA-256が一致しません: $actual" }
      Move-Item -Force $partial $target
      return $target
    } catch {
      Remove-Item -Force -ErrorAction SilentlyContinue $partial
      if ($attempt -ge 3) { throw }
      Start-Sleep -Seconds ([math]::Pow(2, $attempt))
    }
  }
}

# 新しい空ディレクトリへ展開し、最後に印を置きます。途中で中断した展開は次回やり直します。
function Expand-Once([string]$Archive, [string]$Destination, [scriptblock]$Extract) {
  $marker = Join-Path $Destination '.extracted'
  $stamp = Get-Sha256 $Archive
  if ((Test-Path $marker) -and (Get-Content -Raw $marker).Trim() -eq $stamp) { return }
  if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
  New-Item -ItemType Directory -Force $Destination | Out-Null
  & $Extract $Archive $Destination
  Set-Content -NoNewline -Encoding ascii $marker $stamp
}

function Expand-ZipEntries([string]$Archive, [string]$Destination, [scriptblock]$Select) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    foreach ($entry in $zip.Entries) {
      $relative = & $Select $entry.FullName
      if (-not $relative -or $entry.FullName.EndsWith('/')) { continue }
      $path = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
      if (-not $path.StartsWith([IO.Path]::GetFullPath($Destination))) { throw "書庫内の不正なパス: $($entry.FullName)" }
      New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $true)
    }
  } finally { $zip.Dispose() }
}

# FFmpeg: ffmpeg.exe と LICENSE/README だけを取り出します。
$ffmpeg = $config.inputs.ffmpeg
Expand-Once (Get-VerifiedFile $ffmpeg) (Join-Path $cache 'ffmpeg') {
  param($archive, $destination)
  Expand-ZipEntries $archive $destination {
    param($name)
    if ($name -match '^[^/]+/bin/(ffmpeg\.exe)$') { return $Matches[1] }
    if ($name -match '^[^/]+/(LICENSE|README\.txt)$') { return "ffmpeg-$($Matches[1])" }
  }
}
if ((Get-Sha256 (Join-Path $cache 'ffmpeg\ffmpeg.exe')) -ne $ffmpeg.executableSha256) {
  throw 'ffmpeg.exe のSHA-256が release.json と一致しません'
}

# Node.js: 配布物に同梱し、開発時の接続ヘルパー実行と npm にも使います。
$node = $config.inputs.node
Expand-Once (Get-VerifiedFile $node) (Join-Path $cache 'node') {
  param($archive, $destination)
  Expand-ZipEntries $archive $destination {
    param($name)
    if ($name -match '^[^/]+/(.+)$') { return $Matches[1] }
  }
}
$nodeExe = Join-Path $cache 'node\node.exe'
$nodeVersion = (& $nodeExe --version).Trim()
if ($nodeVersion -ne "v$($config.helper.nodeVersion)") { throw "Node.jsの版が違います: $nodeVersion" }

if ($FridaDevkit) {
  $devkit = $config.inputs.fridaCoreDevkit
  Expand-Once (Get-VerifiedFile $devkit) (Join-Path $cache 'frida-core-devkit') {
    param($archive, $destination)
    Invoke-Native 'Frida devkitの展開' { & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $destination }
  }
}

if ($Sources) {
  foreach ($item in $config.correspondingSources) { Get-VerifiedFile $item | Out-Null }
}

# helper/ の依存（frida のネイティブバインディングを含む）を package-lock.json どおりに入れます。
$helper = Join-Path (Split-Path $PSScriptRoot) 'helper'
$env:Path = "$(Split-Path $nodeExe);$env:Path"
Push-Location $helper
try {
  Invoke-Native 'npm ci' { & (Join-Path $cache 'node\npm.cmd') ci --omit=dev --no-audit --no-fund }
} finally { Pop-Location }

Write-Host '依存物の準備ができました。'
