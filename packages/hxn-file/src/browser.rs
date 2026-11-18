use crate::{MAX_BYTES, MAX_PENDING, Preference, path, rejected};
use hxn_future::{Completer, Future};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{
    Arc, Mutex, OnceLock,
    atomic::{AtomicU32, Ordering::SeqCst},
};

#[repr(C)]
struct Mailbox {
    sent: AtomicU32,
    done: AtomicU32,
    request: AtomicU32,
    request_len: AtomicU32,
    reply: AtomicU32,
    capacity: AtomicU32,
    reply_len: AtomicU32,
    changed: AtomicU32,
    wake: AtomicU32,
}
struct Broker {
    mailbox: Box<Mailbox>,
    started: bool,
}
static BROKER: OnceLock<Mutex<Broker>> = OnceLock::new();
static NEXT_CONTEXT: AtomicU32 = AtomicU32::new(1);
static NEXT_JOB: AtomicU32 = AtomicU32::new(1);
struct Pending {
    done: Completer<Vec<u8>>,
    _owner: Arc<Store>,
}
static PENDING: Mutex<BTreeMap<u32, Pending>> = Mutex::new(BTreeMap::new());

#[cfg(target_os = "wasi")]
unsafe extern "C" {
    fn ash_host_agent(name: *const u8, length: u32, address: u32) -> i32;
    fn ash_host_watch(
        word: *const u32,
        handler: unsafe extern "C" fn(*mut std::ffi::c_void),
        context: *mut std::ffi::c_void,
    ) -> *const u32;
}
#[cfg(target_os = "emscripten")]
unsafe extern "C" {
    fn hxn_file_agent(address: u32) -> i32;
}
#[cfg(all(target_os = "emscripten", not(target_feature = "atomics")))]
unsafe extern "C" {
    fn hxn_file_execute();
    fn emscripten_async_call(
        callback: extern "C" fn(*mut std::ffi::c_void),
        context: *mut std::ffi::c_void,
        millis: i32,
    );
}
#[cfg(all(target_os = "emscripten", target_feature = "atomics"))]
static WAKE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

fn next(counter: &AtomicU32) -> Result<u32, String> {
    let mut seen = counter.load(SeqCst);
    loop {
        let after = seen
            .checked_add(1)
            .ok_or("browser file handle space exhausted")?;
        match counter.compare_exchange_weak(seen, after, SeqCst, SeqCst) {
            Ok(_) => return Ok(seen),
            Err(now) => seen = now,
        }
    }
}
#[cfg(target_os = "wasi")]
unsafe extern "C" fn changed(_: *mut std::ffi::c_void) {
    settle();
}
fn start(broker: &mut Broker) -> Result<(), String> {
    if broker.started {
        return Ok(());
    }
    let mailbox = &broker.mailbox;
    #[cfg(target_os = "wasi")]
    {
        let wake = unsafe {
            ash_host_watch(
                mailbox.changed.as_ptr().cast_const(),
                changed,
                std::ptr::null_mut(),
            )
        };
        if wake.is_null() {
            return Err("file operations require a browser page host".into());
        }
        mailbox.wake.store(wake as u32, SeqCst);
    }
    let address = (&**mailbox) as *const Mailbox as u32;
    #[cfg(target_os = "wasi")]
    let running = unsafe { ash_host_agent(b"hxn_file".as_ptr(), 8, address) };
    #[cfg(target_os = "emscripten")]
    let running = unsafe { hxn_file_agent(address) };
    #[cfg(not(any(target_os = "wasi", target_os = "emscripten")))]
    let running = {
        let _ = address;
        0
    };
    if running == 0 {
        return Err("file operations require a browser page host".into());
    }
    #[cfg(all(target_os = "emscripten", target_feature = "atomics"))]
    {
        mailbox.wake.store(WAKE.as_ptr() as u32, SeqCst);
        std::thread::Builder::new()
            .name("hxn file completions".into())
            .spawn(|| {
                let mut seen = 0;
                loop {
                    let now = WAKE.load(SeqCst);
                    if now != seen {
                        seen = now;
                        settle();
                    }
                    unsafe { core::arch::wasm32::memory_atomic_wait32(WAKE.as_ptr(), seen, -1) };
                }
            })
            .map_err(|e| e.to_string())?;
    }
    broker.started = true;
    Ok(())
}
fn request(value: Value) -> Result<Value, String> {
    let broker = BROKER.get_or_init(|| {
        Mutex::new(Broker {
            mailbox: Box::new(Mailbox {
                sent: AtomicU32::new(0),
                done: AtomicU32::new(0),
                request: AtomicU32::new(0),
                request_len: AtomicU32::new(0),
                reply: AtomicU32::new(0),
                capacity: AtomicU32::new(0),
                reply_len: AtomicU32::new(0),
                changed: AtomicU32::new(0),
                wake: AtomicU32::new(0),
            }),
            started: false,
        })
    });
    let mut broker = broker.lock().map_err(|_| "file bridge lock is poisoned")?;
    start(&mut broker)?;
    let bytes = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
    if bytes.len() > 1_048_576 {
        return Err("file request exceeds the transport limit".into());
    }
    let mut reply = vec![0u8; 65536];
    let m = &broker.mailbox;
    m.request.store(bytes.as_ptr() as u32, SeqCst);
    m.request_len.store(bytes.len() as u32, SeqCst);
    m.reply.store(reply.as_mut_ptr() as u32, SeqCst);
    m.capacity.store(reply.len() as u32, SeqCst);
    #[cfg(target_feature = "atomics")]
    {
        let sent = m.sent.fetch_add(1, SeqCst).wrapping_add(1);
        unsafe { core::arch::wasm32::memory_atomic_notify(m.sent.as_ptr().cast(), u32::MAX) };
        loop {
            let seen = m.done.load(SeqCst);
            if seen == sent {
                break;
            }
            unsafe {
                core::arch::wasm32::memory_atomic_wait32(
                    m.done.as_ptr().cast(),
                    seen as i32,
                    1_000_000_000,
                )
            };
        }
    }
    #[cfg(all(target_os = "emscripten", not(target_feature = "atomics")))]
    unsafe {
        hxn_file_execute()
    };
    let length = m.reply_len.load(SeqCst) as usize;
    if length > reply.len() {
        return Err("invalid file reply length".into());
    }
    let value: Value = serde_json::from_slice(&reply[..length]).map_err(|e| e.to_string())?;
    if let Some(error) = value["error"].as_str() {
        return Err(error.into());
    }
    Ok(value["ok"].clone())
}
fn settle() {
    let ids: Vec<u32> = PENDING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .keys()
        .copied()
        .collect();
    for id in ids {
        let result = (|| {
            let status = request(json!({"op":"status","job":id}))?;
            if status["done"].as_bool() != Some(true) {
                return Ok(None);
            }
            if let Some(error) = status["error"].as_str() {
                return Err(error.to_owned());
            }
            let length = status["length"]
                .as_u64()
                .filter(|n| *n <= MAX_BYTES as u64)
                .ok_or("invalid file result size")? as usize;
            let mut bytes = vec![0u8; length];
            request(
                json!({"op":"take","job":id,"address":bytes.as_mut_ptr() as u32,"length":length}),
            )?;
            Ok(Some(bytes))
        })();
        if matches!(result, Ok(None)) {
            continue;
        }
        if result.is_err() {
            let _ = request(json!({"op":"cancel","job":id}));
        }
        let pending = PENDING
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&id);
        if let Some(pending) = pending {
            match result {
                Ok(Some(bytes)) => {
                    pending.done.resolve(bytes);
                }
                Err(error) => {
                    pending.done.reject(error);
                }
                _ => {}
            }
        }
    }
}
#[cfg(all(target_os = "emscripten", not(target_feature = "atomics")))]
static POLLING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(all(target_os = "emscripten", not(target_feature = "atomics")))]
extern "C" fn poll(_: *mut std::ffi::c_void) {
    settle();
    if PENDING.lock().unwrap_or_else(|e| e.into_inner()).is_empty() {
        POLLING.store(false, SeqCst);
    } else {
        unsafe { emscripten_async_call(poll, std::ptr::null_mut(), 4) }
    }
}

pub struct Store {
    id: u32,
}
impl Store {
    pub fn new(application: &str, assets: &str, data: &str) -> Result<Self, String> {
        if !data.is_empty() {
            return Err(
                "browser storage is origin/application scoped; dataRoot is native-only".into(),
            );
        }
        if assets.len() > 8192 {
            return Err("asset base URL is too long".into());
        }
        let id = next(&NEXT_CONTEXT)?;
        request(json!({"op":"open","context":id,"application":application,"assets":assets}))?;
        Ok(Self { id })
    }
    fn submit(self: &Arc<Self>, mut value: Value) -> Future<Vec<u8>> {
        let id = match next(&NEXT_JOB) {
            Ok(id) => id,
            Err(e) => return rejected(e),
        };
        let (done, future) = hxn_future::pending();
        {
            let mut pending = PENDING.lock().unwrap_or_else(|e| e.into_inner());
            if pending.len() >= MAX_PENDING {
                done.reject("too many pending browser file operations".to_owned());
                return future;
            }
            pending.insert(
                id,
                Pending {
                    done,
                    _owner: self.clone(),
                },
            );
        }
        value["op"] = "start".into();
        value["context"] = self.id.into();
        value["job"] = id.into();
        if let Err(error) = request(value) {
            let pending = PENDING
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
            if let Some(pending) = pending {
                pending.done.reject(error);
            }
        }
        #[cfg(all(target_os = "emscripten", not(target_feature = "atomics")))]
        if !POLLING.swap(true, SeqCst) {
            unsafe { emscripten_async_call(poll, std::ptr::null_mut(), 0) }
        };
        future
    }
    pub fn read_asset(self: &Arc<Self>, given: &str) -> Future<Vec<u8>> {
        match path::relative(given) {
            Ok(path) => self.submit(json!({"operation":"asset","path":path})),
            Err(e) => rejected(e),
        }
    }
    pub fn read_save(self: &Arc<Self>, given: &str) -> Future<Vec<u8>> {
        match path::relative(given) {
            Ok(path) => self.submit(json!({"operation":"read","path":path})),
            Err(e) => rejected(e),
        }
    }
    pub fn write_save(self: &Arc<Self>, given: &str, bytes: &[u8]) -> Future<()> {
        let path = match path::relative(given) {
            Ok(p) => p,
            Err(e) => return rejected(e),
        };
        let future=self.submit(json!({"operation":"write","path":path,"address":bytes.as_ptr() as u32,"length":bytes.len()}));
        hxn_future::spawn(async move { future.await.map(|_| ()) })
    }
    pub fn delete_save(self: &Arc<Self>, given: &str) -> Future<bool> {
        let path = match path::relative(given) {
            Ok(p) => p,
            Err(e) => return rejected(e),
        };
        let future = self.submit(json!({"operation":"delete","path":path}));
        hxn_future::spawn(async move { future.await.map(|bytes| bytes.first() == Some(&1)) })
    }
    pub fn get_preference(self: &Arc<Self>, key: &str) -> Future<Preference> {
        if let Err(e) = path::preference(key) {
            return rejected(e);
        }
        let future = self.submit(json!({"operation":"preference","key":key}));
        hxn_future::spawn(async move {
            let bytes = future.await?;
            serde_json::from_slice(&bytes).map_err(|e| hxn_future::Failure::from(e.to_string()))
        })
    }
    pub fn set_preference(self: &Arc<Self>, key: &str, value: &str) -> Future<()> {
        if let Err(e) = path::preference(key) {
            return rejected(e);
        }
        let future = self.submit(json!({"operation":"setPreference","key":key,"value":value}));
        hxn_future::spawn(async move { future.await.map(|_| ()) })
    }
    pub fn delete_preference(self: &Arc<Self>, key: &str) -> Future<bool> {
        if let Err(e) = path::preference(key) {
            return rejected(e);
        }
        let future = self.submit(json!({"operation":"deletePreference","key":key}));
        hxn_future::spawn(async move { future.await.map(|bytes| bytes.first() == Some(&1)) })
    }
}
impl Drop for Store {
    fn drop(&mut self) {
        let _ = request(json!({"op":"close","context":self.id}));
    }
}

pub struct Remote {
    store: Arc<Store>,
}
impl Remote {
    pub fn new(uri: &str, given: &str) -> Result<Self, String> {
        let (_, options) = crate::remote::options(uri, given)?;
        if !options.ca_certificates.is_empty() {
            return Err(
                "browser TLS trust is controlled by the browser; caCertificates is native-only"
                    .into(),
            );
        }
        let id = next(&NEXT_CONTEXT)?;
        request(json!({"op":"remoteOpen","context":id,"uri":uri,"options":options}))?;
        Ok(Self {
            store: Arc::new(Store { id }),
        })
    }
    pub fn read(self: &Arc<Self>) -> Future<Vec<u8>> {
        self.store.submit(json!({"operation":"remoteRead"}))
    }
    pub fn next(self: &Arc<Self>) -> Future<Vec<u8>> {
        self.store.submit(json!({"operation":"remoteNext"}))
    }
    pub fn cancel(&self) {
        let _ = request(json!({"op":"remoteCancel","context":self.store.id}));
    }
}
