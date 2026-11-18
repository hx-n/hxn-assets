//! Scoped file operations; results stay in native-owned futures until collected.
#![cfg_attr(
    all(target_family = "wasm", target_feature = "atomics"),
    feature(stdarch_wasm_atomic_wait)
)]

use hxn_future::Future;
use std::sync::Arc;
#[cfg(not(target_family = "wasm"))]
use std::sync::atomic::{AtomicUsize, Ordering};

#[cfg(target_family = "wasm")]
mod browser;
#[cfg(not(target_family = "wasm"))]
mod native;
mod path;
mod remote;

hxn::package!("hxn.file");

pub const MAX_BYTES: usize = 64 * 1024 * 1024;
const MAX_PENDING: usize = 16;

/// A missing preference is distinct from a stored empty string.
#[hxn::data]
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct Preference {
    pub found: bool,
    pub value: String,
}

#[cfg(target_family = "wasm")]
use browser::Store;
#[cfg(not(target_family = "wasm"))]
use native::Store;

/// Platform implementation used by hxn.file.Storage.
#[hxn::interface(shared)]
pub struct StorageBackend {
    inner: Arc<Store>,
    #[cfg(not(target_family = "wasm"))]
    pending: Arc<AtomicUsize>,
}

#[cfg(not(target_family = "wasm"))]
struct Permit(Arc<AtomicUsize>);
#[cfg(not(target_family = "wasm"))]
impl Drop for Permit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
fn rejected<T>(message: String) -> Future<T> {
    let (done, future) = hxn_future::pending();
    done.reject(message);
    future
}

impl StorageBackend {
    #[cfg(not(target_family = "wasm"))]
    fn reserve(&self) -> Result<Permit, String> {
        let mut count = self.pending.load(Ordering::Acquire);
        loop {
            if count >= MAX_PENDING {
                return Err("too many pending file operations".into());
            }
            match self.pending.compare_exchange_weak(
                count,
                count + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Ok(Permit(self.pending.clone())),
                Err(now) => count = now,
            }
        }
    }

    #[cfg(not(target_family = "wasm"))]
    fn work<T: Send + 'static>(
        &self,
        call: impl FnOnce(&Store) -> Result<T, String> + Send + 'static,
    ) -> Future<T> {
        let permit = match self.reserve() {
            Ok(p) => p,
            Err(e) => return rejected(e),
        };
        let store = self.inner.clone();
        hxn_future::spawn_blocking(move || {
            let _permit = permit;
            call(&store)
        })
    }
}

#[hxn::methods]
impl StorageBackend {
    pub fn new(application: &str, assets: &str, data: &str) -> Result<Self, String> {
        path::application(application)?;
        Ok(Self {
            inner: Arc::new(Store::new(application, assets, data)?),
            #[cfg(not(target_family = "wasm"))]
            pending: Arc::new(AtomicUsize::new(0)),
        })
    }
    pub fn read_asset(&self, path: &str) -> Future<Vec<u8>> {
        let path = path.to_owned();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.read_asset(&path))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.read_asset(&path)
        }
    }
    pub fn read_save(&self, path: &str) -> Future<Vec<u8>> {
        let path = path.to_owned();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.read_save(&path))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.read_save(&path)
        }
    }
    pub fn write_save(&self, path: &str, bytes: &[u8]) -> Future<()> {
        if bytes.len() > MAX_BYTES {
            return rejected("save exceeds the 64 MiB limit".into());
        }
        let path = path.to_owned();
        let bytes = bytes.to_vec();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.write_save(&path, &bytes))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.write_save(&path, &bytes)
        }
    }
    pub fn delete_save(&self, path: &str) -> Future<bool> {
        let path = path.to_owned();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.delete_save(&path))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.delete_save(&path)
        }
    }
    pub fn get_preference(&self, key: &str) -> Future<Preference> {
        let key = key.to_owned();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.get_preference(&key))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.get_preference(&key)
        }
    }
    pub fn set_preference(&self, key: &str, value: &str) -> Future<()> {
        if value.len() > 65_536 {
            return rejected("preference exceeds the 64 KiB limit".into());
        }
        let key = key.to_owned();
        let value = value.to_owned();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.set_preference(&key, &value))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.set_preference(&key, &value)
        }
    }
    pub fn delete_preference(&self, key: &str) -> Future<bool> {
        let key = key.to_owned();
        #[cfg(not(target_family = "wasm"))]
        {
            self.work(move |s| s.delete_preference(&key))
        }
        #[cfg(target_family = "wasm")]
        {
            self.inner.delete_preference(&key)
        }
    }
}

/// One bounded remote chunk or WebSocket message; an empty message is distinct from end.
#[hxn::data]
pub struct RemoteFrame {
    pub end: bool,
    pub text: bool,
    pub bytes: Vec<u8>,
}

/// URI I/O used by the asset package's remote source and streams.
#[hxn::interface(shared)]
pub struct RemoteBackend {
    inner: Arc<remote::Core>,
}
#[hxn::methods]
impl RemoteBackend {
    pub fn new(uri: &str, options: &str) -> Result<Self, String> {
        Ok(Self {
            inner: Arc::new(remote::Core::new(uri, options)?),
        })
    }
    pub fn read(&self) -> Future<Vec<u8>> {
        self.inner.read()
    }
    pub fn next(&self) -> Future<RemoteFrame> {
        let future = self.inner.next();
        hxn_future::spawn(async move {
            let raw = future.await?;
            let kind = *raw
                .first()
                .filter(|kind| **kind <= 2)
                .ok_or("invalid remote frame")?;
            Ok::<_, hxn_future::Failure>(RemoteFrame {
                end: kind == 0,
                text: kind == 2,
                bytes: raw[1..].to_vec(),
            })
        })
    }
    pub fn cancel(&self) {
        self.inner.cancel();
    }
}
impl Drop for RemoteBackend {
    fn drop(&mut self) {
        self.inner.cancel();
    }
}
