use super::{Options, options};
use hxn_future::{Completer, Future};
use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use std::time::{Duration, Instant};
use tungstenite::{Message, WebSocket, client::IntoClientRequest, stream::MaybeTlsStream};

static CONTEXTS: AtomicUsize = AtomicUsize::new(0);
static RESOLVERS: AtomicUsize = AtomicUsize::new(0);
struct ResolverPermit;
impl Drop for ResolverPermit {
    fn drop(&mut self) {
        RESOLVERS.fetch_sub(1, Ordering::AcqRel);
    }
}
struct TimedTcp {
    stream: TcpStream,
    deadline: Option<Instant>,
    write_timeout: Duration,
}
impl TimedTcp {
    fn remaining(&self) -> std::io::Result<Option<Duration>> {
        self.deadline
            .map(|deadline| {
                deadline
                    .checked_duration_since(Instant::now())
                    .ok_or_else(|| {
                        std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "remote handshake timed out",
                        )
                    })
            })
            .transpose()
    }
}
impl Read for TimedTcp {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        self.stream.set_read_timeout(self.remaining()?)?;
        self.stream.read(bytes)
    }
}
impl Write for TimedTcp {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.stream
            .set_write_timeout(self.remaining()?.or(Some(self.write_timeout)))?;
        self.stream.write(bytes)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.stream.flush()
    }
}
enum Connection {
    New,
    Http(Box<dyn Read + Send>),
    Socket(Box<WebSocket<MaybeTlsStream<TimedTcp>>>),
    End,
}
pub struct Core {
    uri: http::Uri,
    options: Options,
    connection: Mutex<Connection>,
    cancelled: AtomicBool,
    pending: Mutex<Option<Completer<Vec<u8>>>>,
    socket: Mutex<Option<TcpStream>>,
}
impl Core {
    pub fn new(uri: &str, given: &str) -> Result<Self, String> {
        let (uri, options) = options(uri, given)?;
        let mut count = CONTEXTS.load(Ordering::Acquire);
        loop {
            if count >= 64 {
                return Err("too many remote asset connections".into());
            }
            match CONTEXTS.compare_exchange_weak(
                count,
                count + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(now) => count = now,
            }
        }
        Ok(Self {
            uri,
            options,
            connection: Mutex::new(Connection::New),
            cancelled: AtomicBool::new(false),
            pending: Mutex::new(None),
            socket: Mutex::new(None),
        })
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        if let Some(done) = self
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            done.reject("remote asset was closed");
        }
        if let Some(socket) = self
            .socket
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
    fn begin(self: &Arc<Self>, whole: bool) -> Future<Vec<u8>> {
        let (done, future) = hxn_future::pending();
        {
            let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            if self.cancelled.load(Ordering::Acquire) {
                done.reject("remote asset was closed");
                return future;
            }
            if pending.is_some() {
                done.reject("only one remote read may be pending per connection");
                return future;
            }
            *pending = Some(done.clone());
        }
        let core = self.clone();
        let fallback = self.clone();
        let fallback_done = done.clone();
        let work = hxn_future::spawn_blocking(move || {
            let result =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| core.receive(whole)))
                    .unwrap_or_else(|_| Err("remote operation panicked".into()));
            let mut pending = core.pending.lock().unwrap_or_else(|e| e.into_inner());
            pending.take();
            if core.cancelled.load(Ordering::Acquire) {
                done.reject("remote asset was closed");
            } else {
                match result {
                    Ok(bytes) => {
                        done.resolve(bytes);
                    }
                    Err(error) => {
                        done.reject(error);
                    }
                }
            }
            Ok::<_, String>(())
        });
        // Thread-start failure must also settle the caller's independently cancellable result.
        drop(hxn_future::spawn(async move {
            if let Err(error) = work.await {
                fallback
                    .pending
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .take();
                fallback_done.reject(error);
            }
            Ok::<_, hxn_future::Failure>(())
        }));
        future
    }
    pub fn read(self: &Arc<Self>) -> Future<Vec<u8>> {
        self.begin(true)
    }
    pub fn next(self: &Arc<Self>) -> Future<Vec<u8>> {
        self.begin(false)
    }
    fn connect(&self, whole: bool) -> Result<Connection, String> {
        if matches!(self.uri.scheme_str(), Some("http" | "https")) {
            let timeout = Duration::from_millis(self.options.timeout_ms);
            let mut builder = ureq::Agent::config_builder()
                .timeout_resolve(Some(timeout))
                .timeout_connect(Some(timeout))
                .timeout_recv_response(Some(timeout))
                .timeout_per_read(Some(timeout))
                .https_only(self.uri.scheme_str() == Some("https"))
                .timeout_global(whole.then_some(timeout));
            if !self.options.ca_certificates.is_empty() {
                let certs = self
                    .options
                    .ca_certificates
                    .iter()
                    .map(|pem| ureq::tls::Certificate::from_pem(pem.as_bytes()))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| e.to_string())?;
                builder = builder.tls_config(
                    ureq::tls::TlsConfig::builder()
                        .root_certs(ureq::tls::RootCerts::Specific(Arc::new(certs)))
                        .build(),
                );
            }
            let agent: ureq::Agent = builder.build().into();
            let mut request = agent.get(self.uri.to_string());
            for (name, value) in &self.options.headers {
                request = request.header(name.as_str(), value.as_str());
            }
            let response = request.call().map_err(|e| e.to_string())?;
            return Ok(Connection::Http(Box::new(
                response.into_body().into_reader(),
            )));
        }
        let started = Instant::now();
        let timeout = Duration::from_millis(self.options.timeout_ms);
        let host = self
            .uri
            .host()
            .ok_or("remote URI has no host")?
            .trim_start_matches('[')
            .trim_end_matches(']');
        let port = self
            .uri
            .port_u16()
            .unwrap_or(if self.uri.scheme_str() == Some("wss") {
                443
            } else {
                80
            });
        let mut count = RESOLVERS.load(Ordering::Acquire);
        loop {
            if count >= 64 {
                return Err("too many pending remote DNS resolutions".into());
            }
            match RESOLVERS.compare_exchange_weak(
                count,
                count + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(now) => count = now,
            }
        }
        let permit = ResolverPermit;
        let hostname = host.to_owned();
        let resolved = hxn_future::spawn_blocking(move || {
            let _permit = permit;
            (hostname.as_str(), port)
                .to_socket_addrs()
                .map(|addresses| addresses.take(16).collect::<Vec<SocketAddr>>())
                .map_err(|e| e.to_string())
        });
        while resolved.wait(Some(Duration::from_millis(50))) == hxn_future::State::Pending {
            if self.cancelled.load(Ordering::Acquire) {
                return Err("remote asset was closed".into());
            }
            if started.elapsed() >= timeout {
                return Err("remote DNS resolution timed out".into());
            }
        }
        let addresses = resolved.take().map_err(|e| e.message)?;
        let mut connected = None;
        for address in addresses {
            if self.cancelled.load(Ordering::Acquire) {
                return Err("remote asset was closed".into());
            }
            let remaining = timeout
                .checked_sub(started.elapsed())
                .ok_or("remote connection timed out")?;
            if let Ok(socket) = TcpStream::connect_timeout(&address, remaining) {
                connected = Some(socket);
                break;
            }
        }
        let socket = connected.ok_or("remote connection failed")?;
        socket
            .set_read_timeout(Some(timeout))
            .map_err(|e| e.to_string())?;
        socket
            .set_write_timeout(Some(timeout))
            .map_err(|e| e.to_string())?;
        *self.socket.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(socket.try_clone().map_err(|e| e.to_string())?);
        let mut request = self
            .uri
            .to_string()
            .into_client_request()
            .map_err(|e| e.to_string())?;
        for (name, value) in &self.options.headers {
            request.headers_mut().insert(
                http::header::HeaderName::from_bytes(name.as_bytes()).map_err(|e| e.to_string())?,
                http::header::HeaderValue::from_str(value).map_err(|e| e.to_string())?,
            );
        }
        if !self.options.protocols.is_empty() {
            request.headers_mut().insert(
                "sec-websocket-protocol",
                self.options
                    .protocols
                    .join(", ")
                    .parse()
                    .map_err(|_| "invalid subprotocols")?,
            );
        }
        let config = tungstenite::protocol::WebSocketConfig::default()
            .max_message_size(Some(self.options.max_bytes))
            .max_frame_size(Some(self.options.max_bytes));
        let connector = if self.options.ca_certificates.is_empty() {
            None
        } else {
            let mut roots = rustls::RootCertStore::empty();
            for pem in &self.options.ca_certificates {
                let cert =
                    ureq::tls::Certificate::from_pem(pem.as_bytes()).map_err(|e| e.to_string())?;
                roots
                    .add(rustls::pki_types::CertificateDer::from(cert.der().to_vec()))
                    .map_err(|e| e.to_string())?;
            }
            Some(tungstenite::Connector::Rustls(Arc::new(
                rustls::ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )))
        };
        let transport = TimedTcp {
            stream: socket,
            deadline: Some(started + timeout),
            write_timeout: timeout,
        };
        let (mut socket, _) =
            tungstenite::client_tls_with_config(request, transport, Some(config), connector)
                .map_err(|e| e.to_string())?;
        // Idle streams wait for a message; explicit cancel shuts down the cloned socket.
        let stream = match socket.get_mut() {
            MaybeTlsStream::Plain(stream) => stream,
            MaybeTlsStream::Rustls(stream) => &mut stream.sock,
            _ => return Err("unsupported TLS transport".into()),
        };
        stream.deadline = None;
        Ok(Connection::Socket(Box::new(socket)))
    }
    fn receive(&self, whole: bool) -> Result<Vec<u8>, String> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| "remote connection lock is poisoned")?;
        if self.cancelled.load(Ordering::Acquire) {
            return Err("remote asset was closed".into());
        }
        if matches!(*connection, Connection::New) {
            *connection = self.connect(whole)?;
        }
        if self.cancelled.load(Ordering::Acquire) {
            *connection = Connection::End;
            return Err("remote asset was closed".into());
        }
        let mut terminal = false;
        let result = match &mut *connection {
            Connection::Http(reader) if whole => {
                let mut bytes = Vec::new();
                reader
                    .take((self.options.max_bytes + 1) as u64)
                    .read_to_end(&mut bytes)
                    .map_err(|e| e.to_string())?;
                if bytes.len() > self.options.max_bytes {
                    return Err("remote asset exceeds its byte limit".into());
                }
                terminal = true;
                Ok(bytes)
            }
            Connection::Http(reader) => {
                let mut bytes = vec![1; self.options.chunk_bytes + 1];
                let size = reader.read(&mut bytes[1..]).map_err(|e| e.to_string())?;
                terminal = size == 0;
                if terminal {
                    Ok(vec![0])
                } else {
                    bytes.truncate(size + 1);
                    Ok(bytes)
                }
            }
            Connection::Socket(_) if whole => Err("WS(S) assets require a stream".into()),
            Connection::Socket(socket) => loop {
                match socket.read() {
                    Ok(Message::Binary(bytes)) => {
                        let mut out = Vec::with_capacity(bytes.len() + 1);
                        out.push(1);
                        out.extend_from_slice(&bytes);
                        break Ok(out);
                    }
                    Ok(Message::Text(text)) => {
                        let mut out = Vec::with_capacity(text.len() + 1);
                        out.push(2);
                        out.extend_from_slice(text.as_bytes());
                        break Ok(out);
                    }
                    Ok(Message::Close(_)) | Err(tungstenite::Error::ConnectionClosed) => {
                        terminal = true;
                        break Ok(vec![0]);
                    }
                    Ok(_) => continue,
                    Err(error) => {
                        terminal = true;
                        break Err(error.to_string());
                    }
                }
            },
            Connection::End if whole => Err("remote response was already consumed".into()),
            Connection::End => Ok(vec![0]),
            Connection::New => unreachable!(),
        };
        if terminal || result.is_err() {
            *connection = Connection::End;
        }
        result
    }
}
impl Drop for Core {
    fn drop(&mut self) {
        self.cancel();
        CONTEXTS.fetch_sub(1, Ordering::AcqRel);
    }
}
