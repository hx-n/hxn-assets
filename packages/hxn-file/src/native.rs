use crate::{MAX_BYTES, Preference, path};
use cap_std::ambient_authority;
use cap_std::fs::{Dir, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub struct Store {
    assets: PathBuf,
    data: Dir,
    #[cfg(target_os = "android")]
    android: Option<android::Assets>,
}
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}

impl Store {
    pub fn new(application: &str, assets: &str, data: &str) -> Result<Self, String> {
        #[cfg(target_os = "android")]
        let android = android::Assets::new()?;
        let base = if !data.is_empty() {
            PathBuf::from(data)
        } else {
            #[cfg(target_os = "android")]
            {
                android.directory.clone()
            }
            #[cfg(not(target_os = "android"))]
            {
                data_directory()?
            }
        };
        let root = base.join(application);
        std::fs::create_dir_all(&root).map_err(error)?;
        let directory = Dir::open_ambient_dir(root, ambient_authority()).map_err(error)?;
        directory.create_dir_all("saves").map_err(error)?;
        directory.create_dir_all("preferences").map_err(error)?;
        let asset_root = if !assets.is_empty() {
            PathBuf::from(assets)
        } else {
            #[cfg(any(target_os = "macos", target_os = "ios"))]
            {
                apple_path(true)?
            }
            #[cfg(not(any(target_os = "macos", target_os = "ios")))]
            {
                PathBuf::from("assets")
            }
        };
        Ok(Self {
            assets: asset_root,
            data: directory,
            #[cfg(target_os = "android")]
            android: assets.is_empty().then_some(android),
        })
    }
    pub fn read_asset(&self, given: &str) -> Result<Vec<u8>, String> {
        let given = path::relative(given)?;
        #[cfg(target_os = "android")]
        if let Some(android) = &self.android {
            return android.read(given);
        }
        let root = Dir::open_ambient_dir(&self.assets, ambient_authority()).map_err(error)?;
        read(&root, given, MAX_BYTES)
    }
    pub fn read_save(&self, given: &str) -> Result<Vec<u8>, String> {
        read(
            &self.data,
            &format!("saves/{}", path::relative(given)?),
            MAX_BYTES,
        )
    }
    pub fn write_save(&self, given: &str, bytes: &[u8]) -> Result<(), String> {
        if bytes.len() > MAX_BYTES {
            return Err("save exceeds the 64 MiB limit".into());
        }
        atomic_write(
            &self.data,
            &format!("saves/{}", path::relative(given)?),
            bytes,
        )
    }
    pub fn delete_save(&self, given: &str) -> Result<bool, String> {
        remove(&self.data, &format!("saves/{}", path::relative(given)?))
    }
    pub fn get_preference(&self, key: &str) -> Result<Preference, String> {
        let name = format!("preferences/{}.txt", path::preference(key)?);
        match read(&self.data, &name, 65_536) {
            Ok(bytes) => Ok(Preference {
                found: true,
                value: String::from_utf8(bytes).map_err(error)?,
            }),
            Err(message) if !self.data.try_exists(&name).map_err(error)? => {
                // Distinguish absence from permission/I/O failures through an open.
                match self.data.open(&name) {
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Preference::default()),
                    _ => Err(message),
                }
            }
            Err(message) => Err(message),
        }
    }
    pub fn set_preference(&self, key: &str, value: &str) -> Result<(), String> {
        atomic_write(
            &self.data,
            &format!("preferences/{}.txt", path::preference(key)?),
            value.as_bytes(),
        )
    }
    pub fn delete_preference(&self, key: &str) -> Result<bool, String> {
        remove(
            &self.data,
            &format!("preferences/{}.txt", path::preference(key)?),
        )
    }
}
fn read(root: &Dir, name: &str, limit: usize) -> Result<Vec<u8>, String> {
    let file = root.open(name).map_err(error)?;
    let metadata = file.metadata().map_err(error)?;
    if !metadata.is_file() {
        return Err("expected a regular file".into());
    }
    if metadata.len() > limit as u64 {
        return Err("file exceeds the read limit".into());
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(error)?;
    if bytes.len() > limit {
        return Err("file exceeds the read limit".into());
    }
    Ok(bytes)
}
fn remove(root: &Dir, name: &str) -> Result<bool, String> {
    match root.remove_file(name) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(error(e)),
    }
}
fn atomic_write(root: &Dir, name: &str, bytes: &[u8]) -> Result<(), String> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = Path::new(name);
    let parent = path.parent().unwrap_or(Path::new("."));
    root.create_dir_all(parent).map_err(error)?;
    let dir = root.open_dir(parent).map_err(error)?;
    let filename = path.file_name().ok_or("file has no name")?;
    for _ in 0..64 {
        let temporary = format!(
            ".hxn-write-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        let mut file = match dir.open_with(&temporary, &options) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(error(e)),
        };
        let written = (|| {
            file.write_all(bytes).map_err(error)?;
            file.sync_all().map_err(error)?;
            drop(file);
            dir.rename(&temporary, &dir, filename).map_err(error)?;
            #[cfg(unix)]
            dir.try_clone()
                .map_err(error)?
                .into_std_file()
                .sync_all()
                .map_err(error)?;
            Ok(())
        })();
        if written.is_err() {
            let _ = dir.remove_file(&temporary);
        }
        return written;
    }
    Err("could not reserve an atomic-save temporary file".into())
}
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn apple_path(assets: bool) -> Result<PathBuf, String> {
    unsafe extern "C" {
        fn hxn_file_apple_path(assets: i32) -> *mut std::ffi::c_char;
        fn hxn_file_string_free(value: *mut std::ffi::c_char);
    }
    // The platform helper returns a fresh malloc-owned UTF-8 path.
    let raw = unsafe { hxn_file_apple_path(i32::from(assets)) };
    if raw.is_null() {
        return Err("Apple application directory is unavailable".into());
    }
    let value = unsafe { std::ffi::CStr::from_ptr(raw) }
        .to_str()
        .map(PathBuf::from)
        .map_err(error);
    unsafe { hxn_file_string_free(raw) };
    value
}
#[cfg(not(target_os = "android"))]
fn data_directory() -> Result<PathBuf, String> {
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        apple_path(false)
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .ok_or("LOCALAPPDATA is unavailable".into())
    }
    #[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "windows")))]
    {
        if let Some(base) = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
        {
            return Ok(base);
        }
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .map(|p| p.join(".local/share"))
            .ok_or("application data directory is unavailable".into())
    }
}
#[cfg(target_os = "android")]
mod android;
