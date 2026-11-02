use super::*;
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;
use zip::write::SimpleFileOptions;

const DATA: &str = "DAMforWindowsToolsData";
const EXE: &str = "DAMforWindowsTools.exe";
const ROOT: &str = "DAMforWindowsTools";
const VERSION: &str = "2.0.1";

/// テスト終了時に消える一時ディレクトリです。
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "updater-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn hash_bytes(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn manifest_text(files: &[(&str, &[u8])]) -> String {
    files
        .iter()
        .map(|(path, content)| format!("{}  {path}\n", hash_bytes(content)))
        .collect()
}

fn write_tree(base: &Path, files: &[(&str, &[u8])]) {
    for (path, content) in files {
        let target = base.join(path);
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(target, content).unwrap();
    }
}

fn write_zip(path: &Path, entries: &[(&str, &[u8])]) {
    let mut writer = zip::ZipWriter::new(File::create(path).unwrap());
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for (name, content) in entries {
        writer.start_file(*name, options).unwrap();
        writer.write_all(content).unwrap();
    }
    writer.finish().unwrap();
}

/// ディレクトリ配下の全ファイル内容と全ディレクトリを、指定名の子を除いて記録します。
fn snapshot(base: &Path, skip: &str) -> (BTreeMap<String, Vec<u8>>, BTreeSet<String>) {
    fn walk(
        dir: &Path,
        prefix: &str,
        skip: &str,
        files: &mut BTreeMap<String, Vec<u8>>,
        dirs: &mut BTreeSet<String>,
    ) {
        for entry in fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let name = entry.file_name().to_string_lossy().into_owned();
            if prefix.is_empty() && name == skip {
                continue;
            }
            let rel = format!("{prefix}{name}");
            if entry.file_type().unwrap().is_dir() {
                dirs.insert(rel.clone());
                walk(&entry.path(), &format!("{rel}/"), skip, files, dirs);
            } else {
                files.insert(rel, fs::read(entry.path()).unwrap());
            }
        }
    }
    let mut files = BTreeMap::new();
    let mut dirs = BTreeSet::new();
    walk(base, "", skip, &mut files, &mut dirs);
    (files, dirs)
}

fn old_release() -> Vec<(&'static str, &'static [u8])> {
    vec![
        (EXE, b"old-exe"),
        ("BUILD_INFO.json", br#"{"releaseVersion":"2.0.0"}"#),
        ("lib/a.dll", b"old-a"),
        ("old-only.txt", b"obsolete"),
    ]
}

fn new_release() -> Vec<(&'static str, &'static [u8])> {
    vec![
        (EXE, b"new-exe"),
        ("BUILD_INFO.json", br#"{"releaseVersion":"2.0.1"}"#),
        ("lib/a.dll", b"new-a"),
        ("lib/b.dll", b"new-b"),
        ("data/flutter_assets/AssetManifest.bin", b"assets"),
    ]
}

/// 旧版がインストール済みで、更新ZIPがダウンロード済みの状態を作ります。
struct Fixture {
    _temp: TempDir,
    install: PathBuf,
    update: PathBuf,
    config: Config,
    _parent: Child,
}

impl Fixture {
    fn new() -> Self {
        Self::with_zip(|update| {
            let archive = update.join("release.zip");
            write_zip(&archive, &zip_entries(&new_release(), None));
            archive
        })
    }

    fn with_zip(build: impl FnOnce(&Path) -> PathBuf) -> Self {
        let temp = TempDir::new();
        let install = temp.0.join("app");
        let old = old_release();
        write_tree(&install, &old);
        fs::write(install.join(MANIFEST_NAME), manifest_text(&old)).unwrap();
        write_tree(
            &install,
            &[(&format!("{DATA}/settings.json"), b"user-data")],
        );
        let update = install.join(DATA).join("updates").join(VERSION);
        fs::create_dir_all(&update).unwrap();
        let archive = build(&update);
        let expected_sha256 = hash_bytes(&fs::read(&archive).unwrap());
        // 終了済みの子プロセスを親とします。Child を保持してPIDの再利用を防ぎます。
        let mut parent = Command::new("cmd")
            .args(["/C", "exit", "0"])
            .spawn()
            .unwrap();
        parent.wait().unwrap();
        let config = Config {
            parent_pid: parent.id(),
            archive,
            install_dir: install.clone(),
            update_dir: update.clone(),
            ready_file: update.join("ready"),
            data_dir_name: DATA.into(),
            exe_name: EXE.into(),
            expected_root: ROOT.into(),
            expected_version: VERSION.into(),
            expected_sha256,
            parent_timeout: Duration::from_secs(10),
        };
        Self {
            _temp: temp,
            install,
            update,
            config,
            _parent: parent,
        }
    }

    fn snapshot(&self) -> (BTreeMap<String, Vec<u8>>, BTreeSet<String>) {
        snapshot(&self.install, DATA)
    }

    /// 起動要求を記録するランチャーで更新を実行し、(終了コード, 起動時のEXE内容) を返します。
    fn run(&self) -> (u8, Vec<Vec<u8>>) {
        let launched = RefCell::new(Vec::new());
        let launcher = |exe: &Path, dir: &Path| -> io::Result<()> {
            assert_eq!(dir, self.install.as_path());
            launched.borrow_mut().push(fs::read(exe)?);
            Ok(())
        };
        let code = run(&self.config, &launcher);
        (code, launched.into_inner())
    }

    fn error_text(&self) -> String {
        let bytes = fs::read(self.update.join(ERROR_FILE_NAME)).expect("error file");
        assert!(
            !bytes.starts_with(b"\xEF\xBB\xBF"),
            "error file must not have a BOM"
        );
        let text = String::from_utf8(bytes).unwrap();
        assert!(
            !text.contains('\n') && !text.contains('\r'),
            "error must be one line"
        );
        text
    }

    fn assert_user_data_intact(&self) {
        let data = fs::read(self.install.join(DATA).join("settings.json")).unwrap();
        assert_eq!(data, b"user-data");
    }
}

/// リリースファイルと SHA256SUMS.txt をZIPエントリへ並べます。`tamper` は記載後に内容を差し替えます。
fn zip_entries(
    files: &[(&'static str, &'static [u8])],
    tamper: Option<(&'static str, &'static [u8])>,
) -> Vec<(&'static str, &'static [u8])> {
    let manifest: &'static str = Box::leak(manifest_text(files).into_boxed_str());
    let mut entries: Vec<(&'static str, &'static [u8])> = files
        .iter()
        .map(|(path, content)| {
            let name: &'static str = Box::leak(format!("{ROOT}/{path}").into_boxed_str());
            match tamper {
                Some((target, replaced)) if target == *path => (name, replaced),
                _ => (name, *content),
            }
        })
        .collect();
    entries.push((
        Box::leak(format!("{ROOT}/{MANIFEST_NAME}").into_boxed_str()),
        manifest.as_bytes(),
    ));
    entries
}

/// 失敗時に配布フォルダが更新前と完全一致し、旧EXEが起動されたことを確認します。
fn assert_failed_and_unchanged(fixture: &Fixture, needle: &str) {
    let before = fixture.snapshot();
    let (code, launched) = fixture.run();
    assert_eq!(code, 1);
    let error = fixture.error_text();
    assert!(error.contains(needle), "unexpected error: {error}");
    assert_eq!(fixture.snapshot(), before);
    assert_eq!(launched, vec![b"old-exe".to_vec()]);
    fixture.assert_user_data_intact();
}

#[test]
fn successful_update_replaces_release_and_cleans_up() {
    let fixture = Fixture::new();
    let (code, launched) = fixture.run();
    assert_eq!(code, 0);
    assert_eq!(launched, vec![b"new-exe".to_vec()]);

    let (files, _) = fixture.snapshot();
    let mut expected: BTreeMap<String, Vec<u8>> = new_release()
        .iter()
        .map(|(p, c)| (p.to_string(), c.to_vec()))
        .collect();
    expected.insert(
        MANIFEST_NAME.into(),
        manifest_text(&new_release()).into_bytes(),
    );
    // 旧マニフェストにだけある old-only.txt は削除されます。
    assert_eq!(files, expected);
    assert!(!fixture.update.exists(), "update dir must be removed");
    fixture.assert_user_data_intact();
}

#[test]
fn update_without_old_manifest_backs_up_new_paths() {
    let fixture = Fixture::new();
    fs::remove_file(fixture.install.join(MANIFEST_NAME)).unwrap();
    let (code, launched) = fixture.run();
    assert_eq!(code, 0);
    assert_eq!(launched, vec![b"new-exe".to_vec()]);
    // 旧マニフェストが無い場合、新版に無い旧ファイルは触りません。
    assert_eq!(
        fs::read(fixture.install.join("old-only.txt")).unwrap(),
        b"obsolete"
    );
    assert_eq!(
        fs::read(fixture.install.join("lib/a.dll")).unwrap(),
        b"new-a"
    );
    fixture.assert_user_data_intact();
}

#[test]
fn archive_hash_mismatch_is_rejected() {
    let mut fixture = Fixture::new();
    fixture.config.expected_sha256 = "0".repeat(64);
    assert_failed_and_unchanged(&fixture, "SHA-256 mismatch");
}

#[test]
fn manifest_hash_mismatch_is_rejected() {
    let fixture = Fixture::with_zip(|update| {
        let archive = update.join("release.zip");
        let entries = zip_entries(&new_release(), Some(("lib/b.dll", b"tampered")));
        write_zip(&archive, &entries);
        archive
    });
    assert_failed_and_unchanged(&fixture, "release file hash mismatch: lib/b.dll");
}

#[test]
fn unlisted_release_file_is_rejected() {
    let fixture = Fixture::with_zip(|update| {
        let archive = update.join("release.zip");
        let mut entries = zip_entries(&new_release(), None);
        entries.push(("DAMforWindowsTools/extra.dll", b"extra"));
        write_zip(&archive, &entries);
        archive
    });
    assert_failed_and_unchanged(&fixture, "not listed");
}

#[test]
fn build_info_version_mismatch_is_rejected() {
    let mut fixture = Fixture::new();
    fixture.config.expected_version = "9.9.9".into();
    assert_failed_and_unchanged(&fixture, "does not match 9.9.9");
}

#[test]
fn unsafe_archive_entries_are_rejected() {
    let cases: [(&str, &str); 7] = [
        ("DAMforWindowsTools/../evil.txt", "invalid path component"),
        ("/abs/evil.txt", "absolute"),
        ("C:/evil.txt", "invalid character"),
        ("DAMforWindowsTools/a.dll:stream", "invalid character"),
        ("DAMforWindowsTools/NUL.txt", "reserved device name"),
        ("Other/evil.txt", "outside the release root"),
        (
            "DAMforWindowsTools\\..\\..\\evil.txt",
            "invalid path component",
        ),
    ];
    for (name, needle) in cases {
        let fixture = Fixture::with_zip(|update| {
            let archive = update.join("release.zip");
            let mut entries = zip_entries(&new_release(), None);
            entries.insert(0, (name, b"evil"));
            write_zip(&archive, &entries);
            archive
        });
        assert_failed_and_unchanged(&fixture, needle);
        assert!(!fixture.update.join("evil.txt").exists());
        assert!(!fixture.install.join("evil.txt").exists());
    }
}

#[test]
fn symlink_entry_is_rejected() {
    let fixture = Fixture::with_zip(|update| {
        let archive = update.join("release.zip");
        let mut writer = zip::ZipWriter::new(File::create(&archive).unwrap());
        writer
            .add_symlink(
                "DAMforWindowsTools/link",
                "C:/Windows",
                SimpleFileOptions::default(),
            )
            .unwrap();
        writer.finish().unwrap();
        archive
    });
    assert_failed_and_unchanged(&fixture, "symbolic link");
}

#[test]
fn manifest_touching_data_directory_is_rejected() {
    let fixture = Fixture::with_zip(|update| {
        let archive = update.join("release.zip");
        let mut files = new_release();
        files.push(("DAMforWindowsToolsData/settings.json", b"overwrite"));
        write_zip(&archive, &zip_entries(&files, None));
        archive
    });
    assert_failed_and_unchanged(&fixture, "protected data path");
}

#[test]
fn update_dir_outside_data_dir_is_rejected_without_touching_anything() {
    let mut fixture = Fixture::new();
    let outside = fixture.install.join("outside");
    fs::create_dir_all(&outside).unwrap();
    fixture.config.update_dir = outside.clone();
    fixture.config.ready_file = outside.join("ready");
    let before = fixture.snapshot();
    let (code, launched) = fixture.run();
    assert_eq!(code, 1);
    assert!(launched.is_empty());
    assert!(!outside.join("ready").exists());
    assert!(!outside.join(ERROR_FILE_NAME).exists());
    assert_eq!(fixture.snapshot(), before);

    // データ領域そのものを update-dir にすることも拒否します。
    fixture.config.update_dir = fixture.install.join(DATA);
    assert_eq!(fixture.run().0, 1);
    fixture.assert_user_data_intact();
}

#[test]
fn archive_outside_update_dir_is_rejected_before_ready() {
    let mut fixture = Fixture::new();
    let outside = fixture.install.join("release.zip");
    fs::copy(&fixture.config.archive, &outside).unwrap();
    fixture.config.archive = fixture
        .update
        .join("..")
        .join("..")
        .join("..")
        .join("release.zip");
    let (code, launched) = fixture.run();
    assert_eq!(code, 1);
    assert!(launched.is_empty());
    assert!(!fixture.config.ready_file.exists());
    assert!(
        fixture
            .error_text()
            .contains("outside the update directory")
    );
}

#[test]
fn failure_during_copy_restores_every_old_file() {
    // 0:EXE 1:BUILD_INFO 2:lib/a.dll 3:lib/b.dll(新規) 4:data/...(新規ディレクトリ配下) 5:SHA256SUMS.txt
    for fail_at in [0, 3, 4, 5] {
        let fixture = Fixture::new();
        let before = fixture.snapshot();
        test_hooks::fail_copy_at(Some(fail_at));
        let (code, launched) = fixture.run();
        test_hooks::fail_copy_at(None);
        assert_eq!(code, 1, "fail_at={fail_at}");
        assert!(fixture.error_text().contains("injected copy failure"));
        assert_eq!(fixture.snapshot(), before, "fail_at={fail_at}");
        assert_eq!(launched, vec![b"old-exe".to_vec()]);
        assert!(
            snapshot(&fixture.update.join(BACKUP_DIR_NAME), "")
                .0
                .is_empty(),
            "backup must be emptied by the rollback"
        );
        fixture.assert_user_data_intact();

        // 同じ更新フォルダで再試行すると成功します。
        let (code, launched) = fixture.run();
        assert_eq!(code, 0, "retry after fail_at={fail_at}");
        assert_eq!(launched, vec![b"new-exe".to_vec()]);
    }
}

#[test]
fn locked_old_file_aborts_backup_and_restores_moved_files() {
    use std::os::windows::fs::OpenOptionsExt;
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    // 共有モード0で開くと移動できないため、退避の途中で失敗させられます。
    let lock = OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(fixture.install.join("old-only.txt"))
        .unwrap();
    let (code, launched) = fixture.run();
    drop(lock);
    assert_eq!(code, 1);
    assert!(fixture.error_text().contains("cannot back up"));
    assert_eq!(fixture.snapshot(), before);
    assert_eq!(launched, vec![b"old-exe".to_vec()]);
}

#[test]
fn stale_backup_is_never_deleted() {
    let fixture = Fixture::new();
    write_tree(
        &fixture.update.join(BACKUP_DIR_NAME),
        &[("lost.dll", b"only copy")],
    );
    assert_failed_and_unchanged(&fixture, "previous backup");
    assert_eq!(
        fs::read(fixture.update.join(BACKUP_DIR_NAME).join("lost.dll")).unwrap(),
        b"only copy"
    );
}

fn spawn_sleeper(seconds: u32) -> Child {
    Command::new("ping")
        .args(["-n", &(seconds + 1).to_string(), "127.0.0.1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

#[test]
fn waits_for_parent_exit_and_times_out() {
    let mut child = spawn_sleeper(1);
    let started = Instant::now();
    wait_for_process_exit(child.id(), Duration::from_secs(20)).unwrap();
    assert!(started.elapsed() >= Duration::from_millis(500));
    assert!(child.try_wait().unwrap().is_some());

    let mut child = spawn_sleeper(30);
    let error = wait_for_process_exit(child.id(), Duration::from_millis(300)).unwrap_err();
    assert!(error.contains("did not exit"));
    child.kill().unwrap();
    child.wait().unwrap();
}

#[test]
fn update_starts_only_after_parent_exits() {
    let mut fixture = Fixture::new();
    let mut parent = spawn_sleeper(30);
    fixture.config.parent_pid = parent.id();
    let ready = fixture.config.ready_file.clone();
    let install = fixture.install.clone();

    std::thread::scope(|scope| {
        let worker = scope.spawn(|| fixture.run());
        let deadline = Instant::now() + Duration::from_secs(10);
        while !ready.exists() {
            assert!(Instant::now() < deadline, "ready file was not written");
            std::thread::sleep(Duration::from_millis(20));
        }
        // ready 後も親が生きている間は配布フォルダに触れません。
        std::thread::sleep(Duration::from_millis(300));
        assert!(parent.try_wait().unwrap().is_none());
        assert_eq!(fs::read(install.join(EXE)).unwrap(), b"old-exe");
        assert!(!worker.is_finished());

        parent.kill().unwrap();
        parent.wait().unwrap();
        let (code, launched) = worker.join().unwrap();
        assert_eq!(code, 0);
        assert_eq!(launched, vec![b"new-exe".to_vec()]);
    });
}

#[test]
fn parent_timeout_fails_without_touching_install() {
    let mut fixture = Fixture::new();
    let mut parent = spawn_sleeper(30);
    fixture.config.parent_pid = parent.id();
    fixture.config.parent_timeout = Duration::from_millis(300);
    let before = fixture.snapshot();
    let (code, launched) = fixture.run();
    parent.kill().unwrap();
    parent.wait().unwrap();
    assert_eq!(code, 1);
    assert!(fixture.config.ready_file.exists());
    assert!(fixture.error_text().contains("did not exit in time"));
    assert_eq!(fixture.snapshot(), before);
    // 親がまだ動いているため、旧EXEを二重起動しません。
    assert!(launched.is_empty());
}

#[test]
fn parse_args_accepts_full_cli_and_rejects_bad_input() {
    let sha = "AB".repeat(32);
    let base = [
        "--parent-pid",
        "1234",
        "--archive",
        r"C:\app\Data\u\r.zip",
        "--install-dir",
        r"C:\app",
        "--update-dir",
        r"C:\app\Data\u",
        "--ready-file",
        r"C:\app\Data\u\ready",
        "--data-dir-name",
        DATA,
        "--exe-name",
        EXE,
        "--expected-root",
        ROOT,
        "--expected-version",
        VERSION,
        "--expected-sha256",
        &sha,
    ];
    let args: Vec<String> = base.iter().map(|s| s.to_string()).collect();
    let config = parse_args(&args).unwrap();
    assert_eq!(config.parent_pid, 1234);
    assert_eq!(config.expected_sha256, "ab".repeat(32));
    assert_eq!(config.parent_timeout, DEFAULT_PARENT_TIMEOUT);

    let with = |extra: &[&str]| {
        let mut v = args.clone();
        v.extend(extra.iter().map(|s| s.to_string()));
        parse_args(&v)
    };
    assert!(with(&["--unknown", "x"]).is_err());
    assert!(with(&["--exe-name", "x.exe"]).is_err());
    assert!(parse_args(&args[..args.len() - 2]).is_err());
    let mut bad = args.clone();
    let last = bad.len() - 1;
    bad[last] = "xyz".into();
    assert!(parse_args(&bad).is_err());
    let mut bad = args.clone();
    bad[11] = r"..\Data".into();
    assert!(parse_args(&bad).is_err());
}
