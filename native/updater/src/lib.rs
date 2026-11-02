//! 親アプリの終了を待ってから検証済みのリリースZIPを配布フォルダへ適用し、失敗時は実際に行った操作だけを巻き戻します。
//!
//! 手順:
//! 1. 引数のパスを検証し、親プロセスのハンドルを確保してから ready ファイルを書き、親の終了を待ちます。
//! 2. ZIP全体のSHA-256を照合し、安全なエントリだけを展開して BUILD_INFO.json と SHA256SUMS.txt を検証します。
//! 3. 旧ファイルを backup へ移動し、新ファイルをコピーします。操作はジャーナルへ積み、失敗時は逆順に戻します。
//! 4. 成功時は新EXEを起動して更新フォルダを削除し、失敗時は理由を書き出して旧EXEを起動します。

use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::windows::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use sha2::{Digest, Sha256};

/// 親アプリの終了を待つ既定の上限です。
pub const DEFAULT_PARENT_TIMEOUT: Duration = Duration::from_secs(90);

const MANIFEST_NAME: &str = "SHA256SUMS.txt";
const BUILD_INFO_NAME: &str = "BUILD_INFO.json";
const ERROR_FILE_NAME: &str = "update-error.txt";
const EXTRACT_DIR_NAME: &str = "extracted";
const BACKUP_DIR_NAME: &str = "backup";
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
// 展開後の合計サイズ上限です。配布物は数百MB程度のため、異常なZIPだけを止めます。
const MAX_EXTRACTED_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// コマンドライン引数から組み立てる更新設定です。
#[derive(Debug, Clone)]
pub struct Config {
    pub parent_pid: u32,
    pub archive: PathBuf,
    pub install_dir: PathBuf,
    pub update_dir: PathBuf,
    pub ready_file: PathBuf,
    pub data_dir_name: String,
    pub exe_name: String,
    pub expected_root: String,
    pub expected_version: String,
    pub expected_sha256: String,
    pub parent_timeout: Duration,
}

/// 起動処理の差し替え口です。引数は (EXEパス, 作業ディレクトリ) です。
pub type Launcher<'a> = &'a dyn Fn(&Path, &Path) -> io::Result<()>;

/// main から呼ばれる入口です。終了コード (0: 成功, 1: 失敗) を返します。
pub fn run_cli(args: &[String]) -> u8 {
    match parse_args(args) {
        Ok(config) => run(&config, &launch_detached),
        Err(_) => 1,
    }
}

/// `--name value` 形式の引数を解析します。未知・重複・欠落はすべて拒否します。
pub fn parse_args(args: &[String]) -> Result<Config, String> {
    const NAMES: [&str; 11] = [
        "parent-pid",
        "archive",
        "install-dir",
        "update-dir",
        "ready-file",
        "data-dir-name",
        "exe-name",
        "expected-root",
        "expected-version",
        "expected-sha256",
        "parent-timeout-ms",
    ];
    let mut values: BTreeMap<&str, String> = BTreeMap::new();
    let mut iter = args.iter();
    while let Some(flag) = iter.next() {
        let name = flag
            .strip_prefix("--")
            .and_then(|n| NAMES.iter().copied().find(|known| *known == n))
            .ok_or_else(|| format!("unknown argument: {flag}"))?;
        let value = iter
            .next()
            .ok_or_else(|| format!("missing value for --{name}"))?;
        if values.insert(name, value.clone()).is_some() {
            return Err(format!("duplicate argument: --{name}"));
        }
    }
    let parent_timeout = match values.remove("parent-timeout-ms") {
        Some(ms) => Duration::from_millis(
            ms.parse()
                .map_err(|_| "invalid --parent-timeout-ms".to_string())?,
        ),
        None => DEFAULT_PARENT_TIMEOUT,
    };
    let mut take = |name: &str| {
        values
            .remove(name)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| format!("missing argument: --{name}"))
    };
    let parent_pid: u32 = take("parent-pid")?
        .parse()
        .map_err(|_| "invalid --parent-pid".to_string())?;
    if parent_pid == 0 || parent_pid == std::process::id() {
        return Err("invalid --parent-pid".into());
    }
    let expected_sha256 = take("expected-sha256")?.to_ascii_lowercase();
    if expected_sha256.len() != 64 || !expected_sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid --expected-sha256".into());
    }
    let config = Config {
        parent_pid,
        archive: take("archive")?.into(),
        install_dir: take("install-dir")?.into(),
        update_dir: take("update-dir")?.into(),
        ready_file: take("ready-file")?.into(),
        data_dir_name: take("data-dir-name")?,
        exe_name: take("exe-name")?,
        expected_root: take("expected-root")?,
        expected_version: take("expected-version")?,
        expected_sha256,
        parent_timeout,
    };
    for (label, name) in [
        ("--data-dir-name", &config.data_dir_name),
        ("--exe-name", &config.exe_name),
        ("--expected-root", &config.expected_root),
    ] {
        validate_component(name).map_err(|e| format!("invalid {label}: {e}"))?;
    }
    Ok(config)
}

/// 更新全体を実行し、終了コードを返します。
pub fn run(config: &Config, launcher: Launcher<'_>) -> u8 {
    // update-dir 自体が信頼できない場合は、どこにも書かずに終了します。
    let paths = match ResolvedPaths::resolve(config) {
        Ok(paths) => paths,
        Err(PathError::Untrusted) => return 1,
        Err(PathError::Rejected(update_dir, reason)) => {
            write_error_file(&update_dir, &reason);
            return 1;
        }
    };

    // 親がまだ動いている段階の失敗では、配布フォルダに触れず旧EXEも起動しません。
    if let Err(reason) = wait_for_parent_after_ready(config, &paths) {
        write_error_file(&paths.update_dir, &reason);
        return 1;
    }

    let mut journal = Journal::default();
    match apply_update(config, &paths, &mut journal, launcher) {
        Ok(()) => {
            // 実行中の updater 自身が中にある場合など、消せないものは次回起動時の清掃へ任せます。
            let _ = fs::remove_dir_all(&paths.update_dir);
            0
        }
        Err(reason) => {
            let message = match journal.rollback() {
                Ok(()) => reason,
                Err(rollback) => format!("{reason}; rollback failed: {rollback}"),
            };
            write_error_file(&paths.update_dir, &message);
            let old_exe = paths.install_dir.join(&config.exe_name);
            if is_regular_file(&old_exe) {
                let _ = launcher(&old_exe, &paths.install_dir);
            }
            1
        }
    }
}

fn launch_detached(exe: &Path, working_dir: &Path) -> io::Result<()> {
    std::process::Command::new(exe)
        .current_dir(working_dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(drop)
}

fn wait_for_parent_after_ready(config: &Config, paths: &ResolvedPaths) -> Result<(), String> {
    // 先にハンドルを握るので、待機中にPIDが再利用されても別プロセスを待つことはありません。
    let parent = ParentProcess::open(config.parent_pid)?;
    fs::write(&paths.ready_file, b"ready").map_err(|e| format!("cannot write ready file: {e}"))?;
    match parent {
        Some(parent) => parent.wait(config.parent_timeout),
        None => Ok(()),
    }
}

// ---------------------------------------------------------------------------
// 親プロセス待機
// ---------------------------------------------------------------------------

struct ParentProcess(windows_sys::Win32::Foundation::HANDLE);

impl ParentProcess {
    /// 親プロセスの待機用ハンドルを開きます。既に存在しない場合は `None` です。
    fn open(pid: u32) -> Result<Option<Self>, String> {
        use windows_sys::Win32::Foundation::{ERROR_INVALID_PARAMETER, GetLastError};
        use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE};
        // SAFETY: OpenProcess はポインタ引数を取らず、失敗時は null を返すだけです。
        let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
        if !handle.is_null() {
            return Ok(Some(Self(handle)));
        }
        // SAFETY: 直前のAPI呼び出しのエラーコードを読むだけです。
        let error = unsafe { GetLastError() };
        if error == ERROR_INVALID_PARAMETER {
            Ok(None)
        } else {
            Err(format!("cannot open parent process {pid}: error {error}"))
        }
    }

    fn wait(&self, timeout: Duration) -> Result<(), String> {
        use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
        use windows_sys::Win32::System::Threading::WaitForSingleObject;
        let millis = u32::try_from(timeout.as_millis())
            .unwrap_or(u32::MAX - 1)
            .min(u32::MAX - 1);
        // SAFETY: self.0 は Drop まで閉じない有効なプロセスハンドルです。
        match unsafe { WaitForSingleObject(self.0, millis) } {
            WAIT_OBJECT_0 => Ok(()),
            WAIT_TIMEOUT => Err("the application did not exit in time".into()),
            other => Err(format!("waiting for the application failed: {other}")),
        }
    }
}

impl Drop for ParentProcess {
    fn drop(&mut self) {
        // SAFETY: OpenProcess で得た所有ハンドルを一度だけ閉じます。
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

/// 指定PIDのプロセス終了を待ちます。既に存在しなければ即座に成功します。
pub fn wait_for_process_exit(pid: u32, timeout: Duration) -> Result<(), String> {
    match ParentProcess::open(pid)? {
        Some(process) => process.wait(timeout),
        None => Ok(()),
    }
}

// ---------------------------------------------------------------------------
// 引数パスの検証
// ---------------------------------------------------------------------------

struct ResolvedPaths {
    archive: PathBuf,
    install_dir: PathBuf,
    update_dir: PathBuf,
    ready_file: PathBuf,
}

enum PathError {
    /// update-dir 自体を信頼できないため、エラーファイルも書きません。
    Untrusted,
    /// update-dir は正しいが、他の引数が不正です。
    Rejected(PathBuf, String),
}

impl ResolvedPaths {
    fn resolve(config: &Config) -> Result<Self, PathError> {
        let untrusted = |_: String| PathError::Untrusted;
        let install_dir = absolute_normal(&config.install_dir).map_err(untrusted)?;
        let update_dir = absolute_normal(&config.update_dir).map_err(untrusted)?;
        let data_dir = install_dir.join(&config.data_dir_name);
        if !is_strictly_within(&update_dir, &data_dir) {
            return Err(untrusted(
                "update directory is outside the application data directory".into(),
            ));
        }
        // データ領域から update-dir までの途中にリパースポイントがあると別の場所を消し得るため拒否します。
        let mut current = data_dir.clone();
        let tail: Vec<_> = update_dir
            .components()
            .skip(data_dir.components().count())
            .collect();
        for part in std::iter::once(None).chain(tail.iter().map(Some)) {
            if let Some(part) = part {
                current.push(part);
            }
            match fs::symlink_metadata(&current) {
                Ok(meta) if meta.is_dir() && !is_reparse(&meta) => {}
                _ => {
                    return Err(untrusted(format!(
                        "not a plain directory: {}",
                        current.display()
                    )));
                }
            }
        }

        let rejected = |reason: String| PathError::Rejected(update_dir.clone(), reason);
        let archive = absolute_normal(&config.archive).map_err(rejected)?;
        if !is_strictly_within(&archive, &update_dir) {
            return Err(rejected(
                "update archive is outside the update directory".into(),
            ));
        }
        let ready_file = absolute_normal(&config.ready_file).map_err(rejected)?;
        if !is_strictly_within(&ready_file, &update_dir) {
            return Err(rejected(
                "ready file is outside the update directory".into(),
            ));
        }
        Ok(Self {
            archive,
            install_dir,
            update_dir,
            ready_file,
        })
    }
}

fn absolute_normal(path: &Path) -> Result<PathBuf, String> {
    let absolute = std::path::absolute(path).map_err(|e| format!("invalid path: {e}"))?;
    // \\?\ 形式では .. が正規化されないため、残っていれば拒否します。
    if absolute
        .components()
        .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(format!("path is not normalized: {}", path.display()));
    }
    Ok(absolute)
}

fn is_strictly_within(child: &Path, parent: &Path) -> bool {
    let child: Vec<_> = child.components().collect();
    let parent: Vec<_> = parent.components().collect();
    child.len() > parent.len()
        && parent.iter().zip(&child).all(|(a, b)| {
            a.as_os_str()
                .to_string_lossy()
                .eq_ignore_ascii_case(&b.as_os_str().to_string_lossy())
        })
}

// ---------------------------------------------------------------------------
// 相対パスの検証
// ---------------------------------------------------------------------------

/// 検証済みの相対パスです。区切りは常に '/' で保持します。
#[derive(Debug, Clone)]
struct RelPath(Vec<String>);

impl RelPath {
    fn parse(raw: &str) -> Result<Self, String> {
        let normalized = raw.replace('\\', "/");
        if normalized.is_empty() || normalized.starts_with('/') {
            return Err(format!("absolute or empty path: {raw}"));
        }
        let parts: Vec<String> = normalized.split('/').map(str::to_owned).collect();
        for (index, part) in parts.iter().enumerate() {
            validate_component(part).map_err(|e| format!("{e}: {raw}"))?;
            // 先頭要素の 8.3 短縮名 (DAMFOR~1 等) でデータ領域を指されないよう '~' を拒否します。
            if index == 0 && part.contains('~') {
                return Err(format!("short-name-like path: {raw}"));
            }
        }
        Ok(Self(parts))
    }

    fn display(&self) -> String {
        self.0.join("/")
    }

    fn key(&self) -> String {
        self.display().to_lowercase()
    }

    fn under(&self, base: &Path) -> PathBuf {
        let mut path = base.to_path_buf();
        path.extend(&self.0);
        path
    }

    fn starts_with_component(&self, name: &str) -> bool {
        self.0[0].eq_ignore_ascii_case(name)
    }
}

/// Windows のファイル名として曖昧さの無い1要素だけを許可します。
fn validate_component(part: &str) -> Result<(), String> {
    const RESERVED: [&str; 22] = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    if part.is_empty() || part == "." || part == ".." {
        return Err("invalid path component".into());
    }
    if part
        .chars()
        .any(|c| c < ' ' || matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*' | '/' | '\\'))
    {
        return Err("invalid character in path".into());
    }
    if part.ends_with('.') || part.ends_with(' ') {
        return Err("path component ends with a dot or space".into());
    }
    let stem = part.split('.').next().unwrap_or(part).trim_end();
    if RESERVED.iter().any(|r| r.eq_ignore_ascii_case(stem)) {
        return Err("reserved device name in path".into());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 更新本体
// ---------------------------------------------------------------------------

fn apply_update(
    config: &Config,
    paths: &ResolvedPaths,
    journal: &mut Journal,
    launcher: Launcher<'_>,
) -> Result<(), String> {
    let actual =
        sha256_file(&paths.archive).map_err(|e| format!("cannot read update archive: {e}"))?;
    if actual != config.expected_sha256 {
        return Err(format!(
            "update archive SHA-256 mismatch: expected {}, got {actual}",
            config.expected_sha256
        ));
    }

    let extract_dir = paths.update_dir.join(EXTRACT_DIR_NAME);
    let backup_dir = paths.update_dir.join(BACKUP_DIR_NAME);
    reset_work_dirs(&extract_dir, &backup_dir)?;
    extract_archive(&paths.archive, &extract_dir, &config.expected_root)?;

    let release_dir = extract_dir.join(&config.expected_root);
    if !is_regular_file(&release_dir.join(&config.exe_name)) {
        return Err("updated executable is missing".into());
    }
    check_build_info(&release_dir.join(BUILD_INFO_NAME), &config.expected_version)?;
    let new_manifest = read_manifest(&release_dir, &config.data_dir_name)?;
    verify_release_tree(&release_dir, &new_manifest)?;

    // 新旧どちらかに記載された既存ファイルは、上書き前に必ず backup へ退避します。
    let manifest_path = RelPath::parse(MANIFEST_NAME)?;
    let mut backup_set = UniquePaths::default();
    if is_regular_file(&paths.install_dir.join(MANIFEST_NAME)) {
        let old_manifest = read_manifest(&paths.install_dir, &config.data_dir_name)
            .map_err(|e| format!("installed {e}"))?;
        for (path, _) in &old_manifest {
            backup_set.insert(path.clone());
        }
    }
    for (path, _) in &new_manifest {
        backup_set.insert(path.clone());
    }
    backup_set.insert(manifest_path.clone());

    for path in &backup_set.items {
        let target = checked_install_target(&paths.install_dir, path)?;
        if fs::symlink_metadata(&target).is_ok() {
            journal.move_file(&target, &path.under(&backup_dir))?;
        }
    }

    let copies = new_manifest
        .iter()
        .map(|(path, _)| path)
        .chain(std::iter::once(&manifest_path));
    for (index, path) in copies.enumerate() {
        let target = checked_install_target(&paths.install_dir, path)?;
        journal.copy_file(
            &path.under(&release_dir),
            &target,
            &paths.install_dir,
            index,
        )?;
    }

    for (path, hash) in &new_manifest {
        let installed = path.under(&paths.install_dir);
        let actual = sha256_file(&installed)
            .map_err(|e| format!("cannot verify installed {}: {e}", path.display()))?;
        if &actual != hash {
            return Err(format!("installed file hash mismatch: {}", path.display()));
        }
    }

    let new_exe = paths.install_dir.join(&config.exe_name);
    launcher(&new_exe, &paths.install_dir)
        .map_err(|e| format!("cannot start the updated application: {e}"))
}

#[derive(Default)]
struct UniquePaths {
    keys: HashSet<String>,
    items: Vec<RelPath>,
}

impl UniquePaths {
    fn insert(&mut self, path: RelPath) {
        if self.keys.insert(path.key()) {
            self.items.push(path);
        }
    }
}

fn reset_work_dirs(extract_dir: &Path, backup_dir: &Path) -> Result<(), String> {
    // 前回のロールバックが失敗していると backup だけが旧ファイルを持つため、消さずに止めます。
    // ロールバック済みなら空ディレクトリしか残らないので、ファイルの有無だけを見ます。
    if backup_dir.exists() && contains_files(backup_dir) {
        return Err("a previous backup directory still contains files".into());
    }
    for dir in [extract_dir, backup_dir] {
        match fs::remove_dir_all(dir) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("cannot clean {}: {e}", dir.display())),
        }
        fs::create_dir(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    Ok(())
}

/// 配下にファイルが1つでもあれば true です。読めない・リパースポイントがある場合も安全側で true とします。
fn contains_files(dir: &Path) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return true;
    };
    entries.into_iter().any(|entry| {
        let Ok(entry) = entry else { return true };
        match fs::symlink_metadata(entry.path()) {
            Ok(meta) if meta.is_dir() && !is_reparse(&meta) => contains_files(&entry.path()),
            _ => true,
        }
    })
}

/// 配布フォルダ内の操作対象について、途中にリパースポイントや想定外の種類が無いか確認します。
fn checked_install_target(install_dir: &Path, path: &RelPath) -> Result<PathBuf, String> {
    let mut current = install_dir.to_path_buf();
    let last = path.0.len() - 1;
    for (index, part) in path.0.iter().enumerate() {
        current.push(part);
        let meta = match fs::symlink_metadata(&current) {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => break,
            Err(e) => return Err(format!("cannot inspect {}: {e}", path.display())),
        };
        if is_reparse(&meta) {
            return Err(format!("reparse point in install path: {}", path.display()));
        }
        let expected_dir = index < last;
        if meta.is_dir() != expected_dir {
            return Err(format!(
                "unexpected entry type in install path: {}",
                path.display()
            ));
        }
    }
    Ok(path.under(install_dir))
}

// ---------------------------------------------------------------------------
// ZIP展開
// ---------------------------------------------------------------------------

fn extract_archive(archive: &Path, extract_dir: &Path, expected_root: &str) -> Result<(), String> {
    let file = File::open(archive).map_err(|e| format!("cannot open update archive: {e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("invalid update archive: {e}"))?;
    let mut seen = HashSet::new();
    let mut total: u64 = 0;
    for index in 0..zip.len() {
        let mut entry = zip
            .by_index(index)
            .map_err(|e| format!("invalid update archive entry: {e}"))?;
        let name = entry
            .name()
            .map_err(|e| format!("invalid update archive entry name: {e}"))?
            .into_owned();
        if entry.is_symlink() {
            return Err(format!("symbolic link in update archive: {name}"));
        }
        let is_dir = entry.is_dir();
        let trimmed = if is_dir {
            name.trim_end_matches(['/', '\\'])
        } else {
            &name
        };
        let path = RelPath::parse(trimmed)?;
        if !path.0[0].eq_ignore_ascii_case(expected_root) || (!is_dir && path.0.len() < 2) {
            return Err(format!("unexpected entry outside the release root: {name}"));
        }
        if !seen.insert(path.key()) {
            return Err(format!("duplicate entry in update archive: {name}"));
        }
        let target = path.under(extract_dir);
        if is_dir {
            fs::create_dir_all(&target).map_err(|e| format!("cannot extract {name}: {e}"))?;
            continue;
        }
        total = total.saturating_add(entry.size());
        if total > MAX_EXTRACTED_BYTES {
            return Err("update archive is too large".into());
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("cannot extract {name}: {e}"))?;
        }
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&target)
            .map_err(|e| format!("cannot extract {name}: {e}"))?;
        io::copy(&mut entry, &mut out).map_err(|e| format!("cannot extract {name}: {e}"))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// リリース内容の検証
// ---------------------------------------------------------------------------

fn check_build_info(path: &Path, expected_version: &str) -> Result<(), String> {
    let bytes = fs::read(path).map_err(|e| format!("cannot read {BUILD_INFO_NAME}: {e}"))?;
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    let json: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid {BUILD_INFO_NAME}: {e}"))?;
    match json.get("releaseVersion").and_then(|v| v.as_str()) {
        Some(version) if version == expected_version => Ok(()),
        Some(version) => Err(format!(
            "{BUILD_INFO_NAME} version {version} does not match {expected_version}"
        )),
        None => Err(format!("{BUILD_INFO_NAME} has no releaseVersion")),
    }
}

/// SHA256SUMS.txt を (相対パス, 小文字ハッシュ) の一覧として読みます。
fn read_manifest(dir: &Path, data_dir_name: &str) -> Result<Vec<(RelPath, String)>, String> {
    let bytes = fs::read(dir.join(MANIFEST_NAME))
        .map_err(|e| format!("{MANIFEST_NAME} is unreadable: {e}"))?;
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    let text = std::str::from_utf8(bytes).map_err(|_| format!("{MANIFEST_NAME} is not UTF-8"))?;
    let mut entries = Vec::new();
    let mut keys = HashSet::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if line.trim().is_empty() {
            continue;
        }
        let (hash, rel) = match (line.get(..64), line.get(64..66), line.get(66..)) {
            (Some(hash), Some("  "), Some(rel)) if hash.bytes().all(|b| b.is_ascii_hexdigit()) => {
                (hash.to_ascii_lowercase(), rel)
            }
            _ => return Err(format!("invalid {MANIFEST_NAME} entry: {line}")),
        };
        let path = RelPath::parse(rel)?;
        if path.starts_with_component(data_dir_name) {
            return Err(format!(
                "{MANIFEST_NAME} contains a protected data path: {rel}"
            ));
        }
        if path.key() == MANIFEST_NAME.to_lowercase() {
            return Err(format!("{MANIFEST_NAME} lists itself"));
        }
        if !keys.insert(path.key()) {
            return Err(format!("duplicate {MANIFEST_NAME} entry: {rel}"));
        }
        entries.push((path, hash));
    }
    if entries.is_empty() {
        return Err(format!("{MANIFEST_NAME} is empty"));
    }
    Ok(entries)
}

/// 展開物がマニフェストと完全一致すること (未記載ファイル無し・全ハッシュ一致) を確認します。
fn verify_release_tree(release_dir: &Path, manifest: &[(RelPath, String)]) -> Result<(), String> {
    let mut found = HashSet::new();
    collect_files(release_dir, "", &mut found)?;
    let mut expected: HashSet<String> = manifest.iter().map(|(p, _)| p.key()).collect();
    expected.insert(MANIFEST_NAME.to_lowercase());
    if let Some(extra) = found.difference(&expected).min() {
        return Err(format!(
            "release file is not listed in {MANIFEST_NAME}: {extra}"
        ));
    }
    if let Some(missing) = expected.difference(&found).min() {
        return Err(format!("release file is missing: {missing}"));
    }
    for (path, hash) in manifest {
        let actual = sha256_file(&path.under(release_dir))
            .map_err(|e| format!("cannot read release file {}: {e}", path.display()))?;
        if &actual != hash {
            return Err(format!("release file hash mismatch: {}", path.display()));
        }
    }
    Ok(())
}

fn collect_files(dir: &Path, prefix: &str, found: &mut HashSet<String>) -> Result<(), String> {
    let entries = fs::read_dir(dir).map_err(|e| format!("cannot list release: {e}"))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("cannot list release: {e}"))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let rel = format!("{prefix}{name}");
        let meta = fs::symlink_metadata(entry.path())
            .map_err(|e| format!("cannot inspect release file {rel}: {e}"))?;
        if is_reparse(&meta) {
            return Err(format!("reparse point in release: {rel}"));
        }
        if meta.is_dir() {
            collect_files(&entry.path(), &format!("{rel}/"), found)?;
        } else {
            found.insert(rel.to_lowercase());
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// ジャーナルとロールバック
// ---------------------------------------------------------------------------

enum Operation {
    /// 旧ファイルを backup へ移動しました。戻すときは逆向きに移動します。
    Moved { from: PathBuf, to: PathBuf },
    /// 配布フォルダに存在しなかったディレクトリを作りました。
    CreatedDir(PathBuf),
    /// 存在しなかった場所へ新ファイルを書き始めました (途中で失敗した部分ファイルも含みます)。
    Copied(PathBuf),
}

#[derive(Default)]
struct Journal(Vec<Operation>);

impl Journal {
    fn move_file(&mut self, from: &Path, to: &Path) -> Result<(), String> {
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("cannot prepare backup: {e}"))?;
        }
        fs::rename(from, to).map_err(|e| format!("cannot back up {}: {e}", from.display()))?;
        self.0.push(Operation::Moved {
            from: from.to_path_buf(),
            to: to.to_path_buf(),
        });
        Ok(())
    }

    fn copy_file(
        &mut self,
        source: &Path,
        target: &Path,
        install_dir: &Path,
        index: usize,
    ) -> Result<(), String> {
        let mut missing_dirs = Vec::new();
        let mut parent = target.parent();
        while let Some(dir) = parent {
            if dir == install_dir || fs::symlink_metadata(dir).is_ok() {
                break;
            }
            missing_dirs.push(dir.to_path_buf());
            parent = dir.parent();
        }
        for dir in missing_dirs.into_iter().rev() {
            fs::create_dir(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
            self.0.push(Operation::CreatedDir(dir));
        }
        if fs::symlink_metadata(target).is_ok() {
            return Err(format!("install target still exists: {}", target.display()));
        }
        // 書き込み前に積むので、途中で失敗した部分ファイルもロールバックで消えます。
        self.0.push(Operation::Copied(target.to_path_buf()));
        #[cfg(test)]
        test_hooks::maybe_fail_copy(index, target)?;
        let _ = index;
        fs::copy(source, target)
            .map(drop)
            .map_err(|e| format!("cannot install {}: {e}", target.display()))
    }

    /// 実際に行った操作だけを逆順に戻します。失敗しても残りの操作は続けます。
    fn rollback(&mut self) -> Result<(), String> {
        let mut failures = Vec::new();
        while let Some(operation) = self.0.pop() {
            match operation {
                Operation::Copied(path) => {
                    if let Err(e) = remove_file_forced(&path)
                        && e.kind() != io::ErrorKind::NotFound
                    {
                        failures.push(format!("remove {}: {e}", path.display()));
                    }
                }
                Operation::CreatedDir(path) => {
                    // 空でなければ残します。中身は本更新が作ったものではありません。
                    let _ = fs::remove_dir(&path);
                }
                Operation::Moved { from, to } => {
                    if let Err(e) = fs::rename(&to, &from) {
                        failures.push(format!("restore {}: {e}", from.display()));
                    }
                }
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join(", "))
        }
    }
}

fn remove_file_forced(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            let mut permissions = fs::metadata(path)?.permissions();
            #[allow(clippy::permissions_set_readonly_false)]
            permissions.set_readonly(false);
            fs::set_permissions(path, permissions)?;
            fs::remove_file(path)
        }
        other => other,
    }
}

// ---------------------------------------------------------------------------
// 共通処理
// ---------------------------------------------------------------------------

fn is_reparse(meta: &fs::Metadata) -> bool {
    meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

fn is_regular_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && !is_reparse(&m))
}

fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// 理由を1行・BOM無しUTF-8で書き出します。
fn write_error_file(update_dir: &Path, reason: &str) {
    let line: String = reason
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    if let Ok(mut file) = File::create(update_dir.join(ERROR_FILE_NAME)) {
        let _ = file.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod test_hooks {
    use std::cell::Cell;
    use std::path::Path;

    thread_local! {
        static FAIL_COPY_AT: Cell<Option<usize>> = const { Cell::new(None) };
    }

    pub fn fail_copy_at(index: Option<usize>) {
        FAIL_COPY_AT.with(|cell| cell.set(index));
    }

    /// 指定番目のコピーで部分ファイルを書いてから失敗させます。
    pub fn maybe_fail_copy(index: usize, target: &Path) -> Result<(), String> {
        if FAIL_COPY_AT.with(Cell::get) == Some(index) {
            std::fs::write(target, b"partial").map_err(|e| e.to_string())?;
            return Err(format!("injected copy failure at {}", target.display()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
