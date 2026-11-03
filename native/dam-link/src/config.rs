//! 起動時に決まる構成（対応DAMの定義・Agentソース・実行設定）と、アプリから届く機能設定です。

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

pub const MANIFEST_FILE_NAME: &str = "supported-dam.json";

/// `config` コマンドの機能設定です。欠損や型違いは安全な初期値（有効）に戻します。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FeatureConfig {
    pub disable_module_check: bool,
    pub disable_foreground_check: bool,
    pub replace_video_urls: bool,
    pub scoring_overlay_enabled: bool,
    pub scoring_show_zero_techniques: bool,
}

impl Default for FeatureConfig {
    fn default() -> Self {
        Self::from_command(&Value::Null)
    }
}

impl FeatureConfig {
    pub fn from_command(command: &Value) -> Self {
        let enabled = |name: &str| command.get(name) != Some(&Value::Bool(false));
        Self {
            disable_module_check: enabled("disableModuleCheck"),
            disable_foreground_check: enabled("disableForegroundCheck"),
            replace_video_urls: enabled("replaceVideoUrls"),
            scoring_overlay_enabled: enabled("scoringOverlayEnabled") && enabled("scoringEnabled"),
            scoring_show_zero_techniques: enabled("scoringShowZeroTechniques"),
        }
    }

    pub fn to_json(self) -> Value {
        json!({
            "disableModuleCheck": self.disable_module_check,
            "disableForegroundCheck": self.disable_foreground_check,
            "replaceVideoUrls": self.replace_video_urls,
            "scoringOverlayEnabled": self.scoring_overlay_enabled,
            "scoringShowZeroTechniques": self.scoring_show_zero_techniques,
        })
    }
}

/// 対応DAMの定義と、注入するAgentソースです。起動後は変わりません。
#[derive(Debug, Clone)]
pub struct TargetConfig {
    pub process_name: String,
    pub supported_hash: String,
    pub label: String,
    pub agent_source: String,
}

/// 起動時に読む環境変数です。
#[derive(Debug, Clone, Default)]
pub struct Environment {
    pub media_origin: Option<String>,
    pub app_root: Option<PathBuf>,
    pub app_version: Option<String>,
}

impl Environment {
    pub fn from_process() -> Self {
        let read = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        Self {
            media_origin: read("DAM_TOOLS_MEDIA_ORIGIN"),
            app_root: read("DAM_TOOLS_APP_ROOT")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute()),
            app_version: read("DAM_TOOLS_APP_VERSION"),
        }
    }
}

/// Agentを構成するファイルです。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentFiles {
    pub manifest: PathBuf,
    /// 結合する順に並べたスクリプトです。
    pub scripts: Vec<PathBuf>,
    /// 採点オーバーレイDLLとアイコンを探すアプリのルートです。
    pub app_root: PathBuf,
}

/// Agentの置き場所を探します。
///
/// - 配布版: `runtime\dam-link.exe` と `runtime\agent\*.js`・`runtime\agent\supported-dam.json`。
/// - 開発時: リポジトリの `helper\identity.js`・`helper\agent\*.js`・`helper\supported-dam.json`。
///   `DAM_TOOLS_APP_ROOT`、なければEXEの上位フォルダから探します。
pub fn locate_agent(exe_dir: &Path, app_root: Option<&Path>) -> Result<AgentFiles, String> {
    let bundled = exe_dir.join("agent");
    if bundled.join(MANIFEST_FILE_NAME).is_file() {
        let root = match app_root {
            Some(root) => root.to_path_buf(),
            None if is_named(exe_dir, "runtime") => {
                exe_dir.parent().unwrap_or(exe_dir).to_path_buf()
            }
            None => exe_dir.to_path_buf(),
        };
        return Ok(AgentFiles {
            manifest: bundled.join(MANIFEST_FILE_NAME),
            scripts: scripts_in(&bundled)?,
            app_root: root,
        });
    }
    let roots = app_root
        .into_iter()
        .chain(exe_dir.ancestors())
        .map(Path::to_path_buf);
    for root in roots {
        let helper = root.join("helper");
        if helper.join(MANIFEST_FILE_NAME).is_file() && helper.join("agent").is_dir() {
            let mut scripts = Vec::new();
            let identity = helper.join("identity.js");
            if identity.is_file() {
                scripts.push(identity);
            }
            scripts.extend(scripts_in(&helper.join("agent"))?);
            return Ok(AgentFiles {
                manifest: helper.join(MANIFEST_FILE_NAME),
                scripts,
                app_root: root,
            });
        }
    }
    Err(format!(
        "Agentが見つかりません（{}\\agent\\{MANIFEST_FILE_NAME}）",
        exe_dir.display()
    ))
}

fn is_named(path: &Path, name: &str) -> bool {
    path.file_name()
        .is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case(name))
}

/// フォルダ直下の `*.js` をファイル名順に返します。
fn scripts_in(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = fs::read_dir(directory)
        .map_err(|e| format!("{} を読めません: {e}", directory.display()))?;
    let mut scripts: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file()
                && path
                    .extension()
                    .is_some_and(|e| e.eq_ignore_ascii_case("js"))
        })
        .collect();
    scripts.sort_by_key(|path| path.file_name().map(|n| n.to_os_string()));
    if scripts.is_empty() {
        return Err(format!("{} にAgentがありません", directory.display()));
    }
    Ok(scripts)
}

impl TargetConfig {
    /// マニフェストと実行設定を検証し、Agentソースを結合します。
    pub fn load(files: &AgentFiles, environment: &Environment) -> Result<Self, String> {
        let text = fs::read_to_string(&files.manifest)
            .map_err(|e| format!("{MANIFEST_FILE_NAME} を読めません: {e}"))?;
        let manifest: Value = serde_json::from_str(&text)
            .map_err(|e| format!("{MANIFEST_FILE_NAME} を解析できません: {e}"))?;
        let target = &manifest["target"];
        let field = |name: &str| target[name].as_str().unwrap_or("").trim().to_owned();
        let process_name = field("processName");
        let file_version = field("fileVersion");
        let supported_hash = field("sha256").to_ascii_lowercase();
        if process_name.is_empty()
            || file_version.is_empty()
            || supported_hash.len() != 64
            || !supported_hash.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(format!(
                "{MANIFEST_FILE_NAME} has an invalid target definition"
            ));
        }

        let media_origin =
            normalize_media_origin(environment.media_origin.as_deref().unwrap_or(""))?;
        let (library_path, asset_directory) =
            resolve_scoring_overlay(&files.app_root, environment.app_version.as_deref());
        let runtime_config = json!({
            "mediaOrigin": media_origin,
            "scoringOverlay": {
                "libraryPath": library_path.map(|p| p.display().to_string()).unwrap_or_default(),
                "assetDirectory": asset_directory.map(|p| p.display().to_string()).unwrap_or_default(),
            },
        });
        let mut sources = Vec::with_capacity(files.scripts.len());
        for script in &files.scripts {
            sources.push(
                fs::read_to_string(script)
                    .map_err(|e| format!("{} を読めません: {e}", script.display()))?,
            );
        }
        Ok(Self {
            process_name,
            supported_hash,
            label: format!("DAM for Windows {file_version}"),
            agent_source: compose_agent_source(&manifest, &runtime_config, &sources),
        })
    }
}

/// マニフェスト・実行設定・各スクリプトを、Fridaへ注入できる1つのスクリプトにします。
pub fn compose_agent_source(
    manifest: &Value,
    runtime_config: &Value,
    sources: &[String],
) -> String {
    let mut source = format!(
        "const DAM_TARGET_MANIFEST = {manifest};\nconst DAM_RUNTIME_CONFIG = {runtime_config};\n"
    );
    let parts: Vec<String> = sources.iter().map(|s| strip_exports(s)).collect();
    source.push_str(&parts.join("\n"));
    source
}

/// ES Module の `export` 修飾子だけを取り除きます（古典スクリプトとして注入するため）。
fn strip_exports(source: &str) -> String {
    // `keyword` の直後が空白なら、その後ろを返します。
    fn after_keyword<'a>(text: &'a str, keyword: &str) -> Option<&'a str> {
        text.strip_prefix(keyword)
            .filter(|rest| rest.starts_with(char::is_whitespace))
            .map(str::trim_start)
    }
    let mut output = String::with_capacity(source.len());
    for line in source.split_inclusive('\n') {
        let body = line.trim_start();
        let indent = &line[..line.len() - body.len()];
        let declaration = after_keyword(body, "export").filter(|rest| {
            let unprefixed = after_keyword(rest, "async")
                .filter(|r| after_keyword(r, "function").is_some())
                .unwrap_or(rest);
            ["function", "class", "const", "let", "var"]
                .iter()
                .any(|keyword| after_keyword(unprefixed, keyword).is_some())
        });
        match declaration {
            Some(rest) => {
                output.push_str(indent);
                output.push_str(rest);
            }
            None => output.push_str(line),
        }
    }
    output
}

/// 動画置換先を、認証情報もパスもない `http://127.0.0.1[:port]` だけに制限します。
pub fn normalize_media_origin(value: &str) -> Result<String, String> {
    const ERROR: &str = "DAM_TOOLS_MEDIA_ORIGIN must be a loopback HTTP origin";
    let value = value.trim();
    let rest = value
        .get(..7)
        .filter(|scheme| scheme.eq_ignore_ascii_case("http://"))
        .map(|_| &value[7..])
        .ok_or(ERROR)?;
    let authority = rest.strip_suffix('/').unwrap_or(rest);
    if authority.contains(['/', '?', '#', '@', '\\']) {
        return Err(ERROR.into());
    }
    let (host, port) = match authority.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    if host != "127.0.0.1" {
        return Err(ERROR.into());
    }
    let port = match port {
        None | Some("") => None,
        Some(port) if port.bytes().all(|b| b.is_ascii_digit()) => {
            Some(port.parse::<u16>().map_err(|_| ERROR)?)
        }
        Some(_) => return Err(ERROR.into()),
    };
    Ok(match port {
        None | Some(80) => "http://127.0.0.1".to_owned(),
        Some(port) => format!("http://127.0.0.1:{port}"),
    })
}

/// 採点オーバーレイDLLとアイコンのフォルダを、決まった候補の中から探します。
pub fn resolve_scoring_overlay(
    root: &Path,
    app_version: Option<&str>,
) -> (Option<PathBuf>, Option<PathBuf>) {
    let suffix = app_version.unwrap_or("").trim().replace('.', "_");
    let versioned = suffix.split('_').count() == 3
        && suffix
            .split('_')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()));
    let mut names = Vec::new();
    if versioned {
        names.push(format!("dam_scoring_overlay_{suffix}.dll"));
    }
    names.push("dam_scoring_overlay.dll".to_owned());
    let build = root
        .join("build")
        .join("windows")
        .join("x64")
        .join("runner");
    let directories = [
        root.to_path_buf(),
        build.join("Release"),
        build.join("Profile"),
        build.join("Debug"),
    ];
    let library = directories
        .iter()
        .flat_map(|directory| names.iter().map(move |name| directory.join(name)))
        .find(|candidate| candidate.is_file());
    let assets = [
        root.join("data")
            .join("flutter_assets")
            .join("assets")
            .join("scoring"),
        root.join("assets").join("scoring"),
    ]
    .into_iter()
    .find(|candidate| candidate.is_dir());
    (library, assets)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feature_config_defaults_to_enabled_and_respects_false() {
        let config = FeatureConfig::from_command(&json!({
            "replaceVideoUrls": false,
            "disableModuleCheck": "no",
            "scoringEnabled": false,
        }));
        assert!(!config.replace_video_urls);
        assert!(config.disable_module_check);
        assert!(!config.scoring_overlay_enabled);
        assert!(config.scoring_show_zero_techniques);
        assert_eq!(config.to_json()["replaceVideoUrls"], json!(false));
    }

    #[test]
    fn media_origin_accepts_only_loopback_http() {
        assert_eq!(
            normalize_media_origin("http://127.0.0.1:8765").unwrap(),
            "http://127.0.0.1:8765"
        );
        assert_eq!(
            normalize_media_origin("HTTP://127.0.0.1:08765/").unwrap(),
            "http://127.0.0.1:8765"
        );
        assert_eq!(
            normalize_media_origin("http://127.0.0.1:80").unwrap(),
            "http://127.0.0.1"
        );
        for bad in [
            "",
            "https://127.0.0.1:8765",
            "http://localhost:8765",
            "http://user@127.0.0.1:8765",
            "http://127.0.0.1:8765/path",
            "http://127.0.0.1:8765?x",
            "http://127.0.0.1:99999",
            "http://127.0.0.1:12a",
        ] {
            assert!(normalize_media_origin(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn strips_only_declaration_exports() {
        let source = "export function a() {}\n  export const b = 1;\nexport async function c() {}\nexport default x;\nconst exported = 1;\nexport { a };\n";
        assert_eq!(
            strip_exports(source),
            "function a() {}\n  const b = 1;\nasync function c() {}\nexport default x;\nconst exported = 1;\nexport { a };\n"
        );
    }

    #[test]
    fn composes_manifest_runtime_config_and_sources() {
        let source = compose_agent_source(
            &json!({"target": {"processName": "x.exe"}}),
            &json!({"mediaOrigin": "http://127.0.0.1:1"}),
            &["export function f() {}".into(), "f();".into()],
        );
        assert!(source.starts_with(
            "const DAM_TARGET_MANIFEST = {\"target\":{\"processName\":\"x.exe\"}};\n"
        ));
        assert!(
            source
                .contains("const DAM_RUNTIME_CONFIG = {\"mediaOrigin\":\"http://127.0.0.1:1\"};\n")
        );
        assert!(source.ends_with("function f() {}\nf();"));
    }

    #[test]
    fn locates_bundled_agent_in_file_name_order() {
        let root = test_dir("bundled");
        let runtime = root.join("runtime");
        let agent = runtime.join("agent");
        fs::create_dir_all(&agent).unwrap();
        fs::write(agent.join(MANIFEST_FILE_NAME), "{}").unwrap();
        for name in ["10_b.js", "00_identity.js", "00_runtime.js", "notes.txt"] {
            fs::write(agent.join(name), "").unwrap();
        }
        let files = locate_agent(&runtime, None).unwrap();
        let names: Vec<String> = files
            .scripts
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["00_identity.js", "00_runtime.js", "10_b.js"]);
        assert_eq!(files.app_root, root);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn locates_development_helper_from_ancestors() {
        let root = test_dir("development");
        let helper = root.join("helper");
        fs::create_dir_all(helper.join("agent")).unwrap();
        fs::write(helper.join(MANIFEST_FILE_NAME), "{}").unwrap();
        fs::write(helper.join("identity.js"), "").unwrap();
        fs::write(helper.join("agent").join("00_runtime.js"), "").unwrap();
        let exe_dir = root.join("native").join("target").join("release");
        fs::create_dir_all(&exe_dir).unwrap();
        let files = locate_agent(&exe_dir, None).unwrap();
        assert_eq!(files.scripts[0], helper.join("identity.js"));
        assert_eq!(files.scripts.len(), 2);
        assert_eq!(files.app_root, root);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn loads_target_and_rejects_invalid_hash() {
        let root = test_dir("target");
        let helper = root.join("helper");
        fs::create_dir_all(helper.join("agent")).unwrap();
        fs::write(helper.join("agent").join("00.js"), "export const x = 1;").unwrap();
        let files = AgentFiles {
            manifest: helper.join(MANIFEST_FILE_NAME),
            scripts: vec![helper.join("agent").join("00.js")],
            app_root: root.clone(),
        };
        let environment = Environment {
            media_origin: Some("http://127.0.0.1:8765".into()),
            ..Environment::default()
        };
        let hash = "A".repeat(64);
        fs::write(
            &files.manifest,
            json!({"target": {"processName": "D.exe", "fileVersion": "1.0", "sha256": hash}})
                .to_string(),
        )
        .unwrap();
        let target = TargetConfig::load(&files, &environment).unwrap();
        assert_eq!(target.supported_hash, "a".repeat(64));
        assert_eq!(target.label, "DAM for Windows 1.0");
        assert!(target.agent_source.ends_with("const x = 1;"));

        fs::write(
            &files.manifest,
            json!({"target": {"processName": "D.exe", "fileVersion": "1.0", "sha256": "xyz"}})
                .to_string(),
        )
        .unwrap();
        assert!(TargetConfig::load(&files, &environment).is_err());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn resolves_versioned_overlay_first() {
        let root = test_dir("overlay");
        fs::create_dir_all(root.join("assets").join("scoring")).unwrap();
        fs::write(root.join("dam_scoring_overlay.dll"), "").unwrap();
        fs::write(root.join("dam_scoring_overlay_2_0_0.dll"), "").unwrap();
        let (library, assets) = resolve_scoring_overlay(&root, Some("2.0.0"));
        assert_eq!(library.unwrap(), root.join("dam_scoring_overlay_2_0_0.dll"));
        assert_eq!(assets.unwrap(), root.join("assets").join("scoring"));
        let (library, _) = resolve_scoring_overlay(&root, Some("bad"));
        assert_eq!(library.unwrap(), root.join("dam_scoring_overlay.dll"));
        fs::remove_dir_all(&root).unwrap();
    }

    fn test_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("dam-link-config-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
