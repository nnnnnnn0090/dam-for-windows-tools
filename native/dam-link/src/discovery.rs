//! DAMプロセスの探索と、実行ファイルのSHA-256計算です（Win32 API）。

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read};
use std::os::windows::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use sha2::{Digest, Sha256};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};

/// 実行ファイル名が完全一致するプロセスのうち、PIDが最も小さいものを返します。
pub fn find_process(exe_name: &str) -> io::Result<Option<u32>> {
    // SAFETY: 引数は定数で、戻り値は下で検査してから使います。
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let snapshot = OwnedHandle(snapshot);
    let mut entry: PROCESSENTRY32W = unsafe_zeroed();
    entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
    let mut found: Option<u32> = None;
    // SAFETY: `entry` は dwSize を設定した有効な構造体で、スナップショットは生存中です。
    let mut more = unsafe { Process32FirstW(snapshot.0, &mut entry) } != 0;
    while more {
        let length = entry
            .szExeFile
            .iter()
            .position(|&c| c == 0)
            .unwrap_or(entry.szExeFile.len());
        if String::from_utf16_lossy(&entry.szExeFile[..length]) == exe_name {
            found = Some(found.map_or(entry.th32ProcessID, |pid| pid.min(entry.th32ProcessID)));
        }
        // SAFETY: 同上。
        more = unsafe { Process32NextW(snapshot.0, &mut entry) } != 0;
    }
    Ok(found)
}

/// プロセスの実行ファイルの完全パスを返します。
pub fn executable_path(pid: u32) -> io::Result<PathBuf> {
    // SAFETY: 戻り値を検査し、OwnedHandle で必ず閉じます。
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return Err(io::Error::last_os_error());
    }
    let process = OwnedHandle(process);
    let mut buffer = vec![0u16; 32 * 1024];
    let mut length = buffer.len() as u32;
    // SAFETY: buffer は length 要素の書き込み可能領域です。
    let ok = unsafe {
        QueryFullProcessImageNameW(
            process.0,
            PROCESS_NAME_WIN32,
            buffer.as_mut_ptr(),
            &mut length,
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    buffer.truncate(length as usize);
    Ok(PathBuf::from(std::ffi::OsString::from_wide(&buffer)))
}

/// 実行ファイルのSHA-256を、パス・サイズ・更新日時をキーに覚えておきます。
#[derive(Default)]
pub struct HashCache {
    entries: HashMap<PathBuf, (u64, Option<SystemTime>, String)>,
}

impl HashCache {
    const MAXIMUM_ENTRIES: usize = 16;

    /// 小文字16進のSHA-256を返します。
    pub fn sha256(&mut self, path: &Path) -> io::Result<String> {
        let metadata = std::fs::metadata(path)?;
        let size = metadata.len();
        let modified = metadata.modified().ok();
        if let Some((cached_size, cached_modified, hash)) = self.entries.get(path)
            && *cached_size == size
            && *cached_modified == modified
            && modified.is_some()
        {
            return Ok(hash.clone());
        }
        let hash = sha256_file(path)?;
        if self.entries.len() >= Self::MAXIMUM_ENTRIES {
            self.entries.clear();
        }
        self.entries
            .insert(path.to_path_buf(), (size, modified, hash.clone()));
        Ok(hash)
    }
}

pub fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
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

struct OwnedHandle(HANDLE);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        // SAFETY: 有効なハンドルだけを保持しており、ここで一度だけ閉じます。
        unsafe { CloseHandle(self.0) };
    }
}

fn unsafe_zeroed<T: Copy>() -> T {
    // SAFETY: PROCESSENTRY32W はすべてのビットが0でも有効なPOD構造体です。
    unsafe { std::mem::zeroed() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_current_process_and_its_executable() {
        let exe = std::env::current_exe().unwrap();
        let name = exe.file_name().unwrap().to_string_lossy().into_owned();
        let pid = find_process(&name).unwrap().unwrap();
        assert!(pid <= std::process::id());
        let path = executable_path(std::process::id()).unwrap();
        assert_eq!(path.canonicalize().unwrap(), exe.canonicalize().unwrap());
        assert_eq!(find_process("no-such-process-dam-link.exe").unwrap(), None);
    }

    #[test]
    fn caches_hash_until_file_changes() {
        let path = std::env::temp_dir().join(format!("dam-link-hash-{}", std::process::id()));
        std::fs::write(&path, b"abc").unwrap();
        let mut cache = HashCache::default();
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert_eq!(cache.sha256(&path).unwrap(), expected);
        assert_eq!(cache.sha256(&path).unwrap(), expected);
        std::fs::write(&path, b"abcd").unwrap();
        assert_ne!(cache.sha256(&path).unwrap(), expected);
        std::fs::remove_file(&path).unwrap();
    }
}
