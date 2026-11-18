use hxn_file::StorageBackend;
use hxn_future::{Future, State};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
struct Fixture {
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "hxn file {} {}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(root.join("assets/nested")).unwrap();
        std::fs::write(root.join("assets/nested/hello.txt"), b"bundled hello\n").unwrap();
        Self { root }
    }
    fn open(&self, app: &str) -> StorageBackend {
        StorageBackend::new(
            app,
            self.root.join("assets").to_str().unwrap(),
            self.root.join("data").to_str().unwrap(),
        )
        .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn result<T>(future: Future<T>) -> Result<T, hxn_future::Failure> {
    assert!(future.wait(Some(Duration::from_secs(5))) != State::Pending);
    future.take()
}
#[test]
fn bundled_files_saves_and_preferences_survive_reopening() {
    let f = Fixture::new();
    let a = f.open("org.hxn.check");
    assert_eq!(
        result(a.read_asset("nested/hello.txt")).unwrap(),
        b"bundled hello\n"
    );
    result(a.write_save("slots/one.bin", &[0, 1, 255, 0, 9])).unwrap();
    result(a.set_preference("empty", "")).unwrap();
    result(a.set_preference("日本語", "héllo 🎨")).unwrap();
    drop(a);
    let b = f.open("org.hxn.check");
    assert_eq!(
        result(b.read_save("slots/one.bin")).unwrap(),
        [0, 1, 255, 0, 9]
    );
    let empty = result(b.get_preference("empty")).unwrap();
    assert!(empty.found);
    assert_eq!(empty.value, "");
    let text = result(b.get_preference("日本語")).unwrap();
    assert!(text.found);
    assert_eq!(text.value, "héllo 🎨");
    assert!(!result(b.get_preference("missing")).unwrap().found);
    assert!(result(b.delete_save("slots/one.bin")).unwrap());
    assert!(!result(b.delete_save("slots/one.bin")).unwrap());
    assert!(result(b.delete_preference("empty")).unwrap());
    assert!(!result(b.get_preference("empty")).unwrap().found);
}
#[test]
fn namespaces_and_read_only_asset_roots_are_distinct() {
    let f = Fixture::new();
    let a = f.open("org.hxn.one");
    let b = f.open("org.hxn.two");
    result(a.write_save("nested/hello.txt", b"save")).unwrap();
    result(a.set_preference("key", "one")).unwrap();
    assert!(result(b.read_save("nested/hello.txt")).is_err());
    assert!(!result(b.get_preference("key")).unwrap().found);
    assert_eq!(
        result(a.read_asset("nested/hello.txt")).unwrap(),
        b"bundled hello\n"
    );
}
#[test]
fn invalid_names_fail_the_future_and_cannot_escape_the_root() {
    let f = Fixture::new();
    let a = f.open("org.hxn.safe");
    for bad in [
        "",
        "../outside",
        "/absolute",
        "a/../b",
        "a//b",
        "C:/file",
        "a\\b",
        "NUL.txt",
        "a.",
        "a ",
        "bad\0name",
    ] {
        assert!(result(a.write_save(bad, b"no")).is_err(), "{bad:?}");
        assert!(result(a.read_asset(bad)).is_err(), "{bad:?}");
    }
    assert!(result(a.set_preference("", "bad")).is_err());
    assert!(result(a.set_preference(&"k".repeat(97), "bad")).is_err());
    assert!(result(a.set_preference("key", &"v".repeat(65_537))).is_err());
    assert!(!f.root.join("outside").exists());
}
#[test]
fn replacing_saves_is_atomic_to_readers_and_preserves_complete_payloads() {
    let f = Fixture::new();
    let store = std::sync::Arc::new(f.open("org.hxn.atomic"));
    let one = vec![1; 65536];
    let two = vec![2; 65536];
    result(store.write_save("slot", &one)).unwrap();
    let writer = store.clone();
    let thread = std::thread::spawn(move || {
        for i in 0..32 {
            result(writer.write_save("slot", if i % 2 == 0 { &two } else { &one })).unwrap();
        }
    });
    for _ in 0..32 {
        let bytes = result(store.read_save("slot")).unwrap();
        assert_eq!(bytes.len(), 65536);
        assert!(bytes.iter().all(|b| *b == bytes[0]));
        assert!(matches!(bytes[0], 1 | 2));
    }
    thread.join().unwrap();
    let entries = std::fs::read_dir(f.root.join("data/org.hxn.atomic/saves"))
        .unwrap()
        .count();
    assert_eq!(entries, 1);
}
#[test]
fn independent_preferences_do_not_lose_concurrent_updates() {
    let f = Fixture::new();
    let mut jobs = Vec::new();
    for n in 0..8 {
        let store = f.open("org.hxn.preferences");
        jobs.push(std::thread::spawn(move || {
            result(store.set_preference(&format!("key{n}"), &format!("value{n}"))).unwrap()
        }));
    }
    for job in jobs {
        job.join().unwrap();
    }
    let store = f.open("org.hxn.preferences");
    for n in 0..8 {
        assert_eq!(
            result(store.get_preference(&format!("key{n}")))
                .unwrap()
                .value,
            format!("value{n}")
        );
    }
}
#[cfg(unix)]
#[test]
fn symlinks_cannot_escape_an_opened_directory() {
    let f = Fixture::new();
    let a = f.open("org.hxn.symlink");
    std::fs::write(f.root.join("private.txt"), b"private").unwrap();
    std::os::unix::fs::symlink(f.root.join("private.txt"), f.root.join("assets/link")).unwrap();
    assert!(result(a.read_asset("link")).is_err());
    std::os::unix::fs::symlink(&f.root, f.root.join("data/org.hxn.symlink/saves/elsewhere"))
        .unwrap();
    assert!(result(a.write_save("elsewhere/escape", b"bad")).is_err());
    assert!(!f.root.join("escape").exists());
}
