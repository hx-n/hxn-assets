use crate::MAX_BYTES;
use std::ffi::{CStr, CString, c_char, c_void};
use std::path::PathBuf;

unsafe extern "C" {
    fn hxn_file_android_new(
        vm: *mut c_void,
        context: *mut c_void,
        directory: *mut *mut c_char,
    ) -> *mut c_void;
    fn hxn_file_android_free(state: *mut c_void);
    fn hxn_file_string_free(value: *mut c_char);
    fn hxn_file_android_open(
        state: *mut c_void,
        name: *const c_char,
        size: *mut i64,
    ) -> *mut c_void;
    fn hxn_file_android_read(asset: *mut c_void, bytes: *mut c_void, size: u32) -> i32;
    fn hxn_file_android_close(asset: *mut c_void);
}

// AAssetManager permits concurrent opens. Each operation owns its AAsset;
// the JNI global reference remains alive until the last Store/operation drops.
pub struct Assets {
    state: usize,
    pub directory: PathBuf,
}
impl Assets {
    pub fn new() -> Result<Self, String> {
        let context = std::panic::catch_unwind(ndk_context::android_context)
            .map_err(|_| "Android host must initialize ndk-context before opening storage")?;
        let mut path = std::ptr::null_mut();
        let state = unsafe { hxn_file_android_new(context.vm(), context.context(), &mut path) };
        if state.is_null() {
            return Err("Android AssetManager/application directory is unavailable".into());
        }
        let directory = if path.is_null() {
            Err("Android files directory is unavailable".to_owned())
        } else {
            let result = unsafe { CStr::from_ptr(path) }
                .to_str()
                .map(PathBuf::from)
                .map_err(|e| e.to_string());
            unsafe { hxn_file_string_free(path) };
            result
        };
        match directory {
            Ok(directory) => Ok(Self {
                state: state as usize,
                directory,
            }),
            Err(error) => {
                unsafe { hxn_file_android_free(state) };
                Err(error)
            }
        }
    }
    pub fn read(&self, name: &str) -> Result<Vec<u8>, String> {
        let name = CString::new(name).map_err(|e| e.to_string())?;
        let mut size = 0;
        let pointer =
            unsafe { hxn_file_android_open(self.state as *mut c_void, name.as_ptr(), &mut size) };
        if pointer.is_null() {
            return Err("bundled APK asset was not found".into());
        }
        let asset = Asset(pointer);
        let size = usize::try_from(size).map_err(|_| "invalid APK asset size")?;
        if size > MAX_BYTES {
            return Err("APK asset exceeds the 64 MiB read limit".into());
        }
        let mut bytes = vec![0u8; size];
        let mut offset = 0;
        while offset < size {
            let count = unsafe {
                hxn_file_android_read(
                    asset.0,
                    bytes[offset..].as_mut_ptr().cast(),
                    (size - offset).min(1_048_576) as u32,
                )
            };
            if count <= 0 {
                return Err("APK asset read failed or ended early".into());
            }
            offset += count as usize;
        }
        Ok(bytes)
    }
}
impl Drop for Assets {
    fn drop(&mut self) {
        unsafe { hxn_file_android_free(self.state as *mut c_void) };
    }
}
struct Asset(*mut c_void);
impl Drop for Asset {
    fn drop(&mut self) {
        unsafe { hxn_file_android_close(self.0) };
    }
}
