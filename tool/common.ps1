# tool/ のスクリプトで共有する関数です。

function Read-ReleaseConfig {
  Get-Content -Raw -Encoding utf8 (Join-Path $PSScriptRoot 'release.json') | ConvertFrom-Json
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# ネイティブコマンドは失敗しても例外にならないため、終了コードで判定して例外にします。
# Windows PowerShell 5.1 は stderr への出力も例外にしてしまうため、この中では止めません。
function Invoke-Native([string]$Description, [scriptblock]$Command) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Command 2>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  if ($code -ne 0) { throw "$Description に失敗しました (終了コード $code)" }
}

# 配布物の全ファイルのSHA-256一覧を `<hash>  <相対パス>` 形式で返します（パス順）。
function Get-ReleaseManifest([string]$Root) {
  $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  Get-ChildItem -LiteralPath $Root -Recurse -File |
    ForEach-Object { $_.FullName.Substring($rootPath.Length).Replace('\', '/') } |
    Where-Object { $_ -ne 'SHA256SUMS.txt' } |
    Sort-Object -CaseSensitive |
    ForEach-Object { "$(Get-Sha256 (Join-Path $Root $_))  $_" }
}
