use crate::MAX_BYTES;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct Options {
    pub timeout_ms: u64,
    pub max_bytes: usize,
    pub chunk_bytes: usize,
    pub headers: BTreeMap<String, String>,
    pub protocols: Vec<String>,
    pub ca_certificates: Vec<String>,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            timeout_ms: 30_000,
            max_bytes: 16 * 1024 * 1024,
            chunk_bytes: 65_536,
            headers: BTreeMap::new(),
            protocols: Vec::new(),
            ca_certificates: Vec::new(),
        }
    }
}
pub fn options(uri: &str, json: &str) -> Result<(http::Uri, Options), String> {
    if uri.len() > 8192 || uri.contains('#') {
        return Err("invalid remote URI".into());
    }
    let uri: http::Uri = uri.parse().map_err(|_| "invalid remote URI")?;
    if !matches!(uri.scheme_str(), Some("http" | "https" | "ws" | "wss"))
        || uri.host().is_none()
        || uri.authority().is_some_and(|a| a.as_str().contains('@'))
    {
        return Err(
            "remote assets require an HTTP(S) or WS(S) URI without embedded credentials".into(),
        );
    }
    let mut options: Options = if json.is_empty() {
        Options::default()
    } else {
        serde_json::from_str(json).map_err(|e| e.to_string())?
    };
    if options.timeout_ms == 0
        || options.timeout_ms > 300_000
        || options.max_bytes == 0
        || options.max_bytes >= MAX_BYTES
        || options.chunk_bytes == 0
        || options.chunk_bytes > 1_048_576
        || options.headers.len() > 32
        || options.protocols.len() > 16
        || options.ca_certificates.len() > 16
    {
        return Err("remote asset options exceed their bounds".into());
    }
    options.chunk_bytes = options.chunk_bytes.min(options.max_bytes);
    if options
        .ca_certificates
        .iter()
        .any(|cert| cert.len() > 32768)
    {
        return Err("CA certificate is too large".into());
    }
    for (name, value) in &options.headers {
        http::header::HeaderName::from_bytes(name.as_bytes())
            .map_err(|_| "invalid remote header name")?;
        http::header::HeaderValue::from_str(value).map_err(|_| "invalid remote header value")?;
        if name.len() + value.len() > 8192 {
            return Err("remote header is too long".into());
        }
    }
    for protocol in &options.protocols {
        if protocol.is_empty()
            || protocol.len() > 256
            || !protocol
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
        {
            return Err("invalid WebSocket subprotocol".into());
        }
    }
    Ok((uri, options))
}

#[cfg(not(target_family = "wasm"))]
mod native;
#[cfg(target_family = "wasm")]
pub use crate::browser::Remote as Core;
#[cfg(not(target_family = "wasm"))]
pub use native::Core;
