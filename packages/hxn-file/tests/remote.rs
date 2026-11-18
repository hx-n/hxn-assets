#![cfg(not(target_family = "wasm"))]
use hxn_file::RemoteBackend;
use hxn_future::{Future, State};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::Duration;
fn take<T>(future: Future<T>) -> Result<T, hxn_future::Failure> {
    assert!(
        future.wait(Some(Duration::from_secs(5))) != State::Pending,
        "remote future timed out"
    );
    future.take()
}
fn http(body: Vec<u8>) -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let uri = format!("http://{}/asset?version=1", listener.local_addr().unwrap());
    let work = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut header = Vec::new();
        let mut byte = [0];
        while !header.ends_with(b"\r\n\r\n") {
            socket.read_exact(&mut byte).unwrap();
            header.push(byte[0]);
            assert!(header.len() < 16384);
        }
        assert!(header.starts_with(b"GET /asset?version=1 HTTP/1.1"));
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .unwrap();
        let _ = socket.write_all(&body);
    });
    (uri, work)
}
#[test]
fn http_snapshots_chunks_and_limits() {
    let (uri, server) = http(vec![0, 1, 255, 0, 9]);
    let backend = RemoteBackend::new(&uri, "{}").unwrap();
    assert_eq!(take(backend.read()).unwrap(), [0, 1, 255, 0, 9]);
    server.join().unwrap();
    let (uri, server) = http((0..100).collect());
    let backend = RemoteBackend::new(&uri, r#"{"chunkBytes":7}"#).unwrap();
    let mut joined = Vec::new();
    loop {
        let frame = take(backend.next()).unwrap();
        if frame.end {
            break;
        }
        assert!(frame.bytes.len() <= 7);
        joined.extend(frame.bytes);
    }
    assert_eq!(joined, (0..100).collect::<Vec<u8>>());
    server.join().unwrap();
    let (uri, server) = http(vec![1; 100]);
    let backend = RemoteBackend::new(&uri, r#"{"maxBytes":10}"#).unwrap();
    assert!(take(backend.read()).is_err());
    server.join().unwrap();
}
#[test]
fn websocket_message_boundaries_and_empty_frames() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let uri = format!("ws://{}/asset", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut peer = tungstenite::accept(socket).unwrap();
        peer.send(tungstenite::Message::Text("hello".into()))
            .unwrap();
        peer.send(tungstenite::Message::Binary(vec![0, 255].into()))
            .unwrap();
        peer.send(tungstenite::Message::Binary(Vec::new().into()))
            .unwrap();
        peer.close(None).unwrap();
    });
    let backend = RemoteBackend::new(&uri, "{}").unwrap();
    let a = take(backend.next()).unwrap();
    assert!(!a.end && a.text);
    assert_eq!(a.bytes, b"hello");
    let b = take(backend.next()).unwrap();
    assert!(!b.end && !b.text);
    assert_eq!(b.bytes, [0, 255]);
    let empty = take(backend.next()).unwrap();
    assert!(!empty.end && empty.bytes.is_empty());
    assert!(take(backend.next()).unwrap().end);
    server.join().unwrap();
}
#[test]
fn closing_a_pending_read_settles_it_without_waiting_for_network_data() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let uri = format!("ws://{}/idle", listener.local_addr().unwrap());
    let (ready, connected) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let _peer = tungstenite::accept(socket).unwrap();
        ready.send(()).unwrap();
        std::thread::sleep(Duration::from_millis(100));
    });
    let backend = RemoteBackend::new(&uri, "{}").unwrap();
    let future = backend.next();
    connected.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(take(backend.next()).is_err());
    backend.cancel();
    assert!(future.wait(Some(Duration::from_millis(500))) != State::Pending);
    assert!(future.take().is_err());
    server.join().unwrap();
}
#[test]
fn invalid_uris_and_transport_options_are_rejected_before_io() {
    for uri in [
        "file:///tmp/private",
        "ftp://example.com/asset",
        "https://user:secret@example.com/a",
        "wss://example.com/a#fragment",
    ] {
        assert!(RemoteBackend::new(uri, "{}").is_err());
    }
    assert!(RemoteBackend::new("https://example.com", r#"{"timeoutMs":0}"#).is_err());
    assert!(
        RemoteBackend::new(
            "https://example.com",
            r#"{"headers":{"X-Test":"line\r\nbreak"}}"#
        )
        .is_err()
    );
}
