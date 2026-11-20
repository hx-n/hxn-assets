//! Owned, serialized graph operations for the installed Haxe asset API.
use hxn_assets_kyugraph::{Database, KnowledgeAdapter, TypedValue};
use hxn_future::Future;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};

hxn::package!("hxn.assets.native");

const MAX_BATCH: usize = 1_048_576;
const MAX_QUERY: usize = 65_536;
const MAX_PENDING: usize = 8;

struct OpenGraph {
    adapter: KnowledgeAdapter,
    database: Database,
}
struct State {
    graph: Mutex<Option<OpenGraph>>,
    started: AtomicBool,
    closing: AtomicBool,
    pending: AtomicUsize,
}
struct Permit(Arc<State>);
impl Drop for Permit {
    fn drop(&mut self) {
        self.0.pending.fetch_sub(1, Ordering::AcqRel);
    }
}
fn reject<T>(message: impl Into<String>) -> Future<T> {
    let (done, future) = hxn_future::pending();
    done.reject(message.into());
    future
}

// Defer the first real step to hxn's bounded pool (or its threadless queue).
fn background<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Future<T> {
    let mut first = true;
    let mut work = Some(work);
    hxn_future::stepped(move || {
        if std::mem::take(&mut first) {
            return std::task::Poll::Pending;
        }
        std::task::Poll::Ready(work.take().expect("one-shot graph operation")())
    })
}

/// Internal generated binding; applications use hxn.assets.KnowledgeGraph.
#[hxn::interface(shared)]
pub struct GraphBackend {
    state: Arc<State>,
}

impl Default for GraphBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl GraphBackend {
    fn work<T: Send + 'static>(
        &self,
        call: impl FnOnce(&mut Option<OpenGraph>) -> Result<T, String> + Send + 'static,
    ) -> Future<T> {
        if self.state.closing.load(Ordering::Acquire) {
            return reject("knowledge graph is closed");
        }
        let mut count = self.state.pending.load(Ordering::Acquire);
        loop {
            if count >= MAX_PENDING {
                return reject("too many pending graph operations");
            }
            match self.state.pending.compare_exchange_weak(
                count,
                count + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(value) => count = value,
            }
        }
        let state = self.state.clone();
        let permit = Permit(state.clone());
        background(move || {
            let _permit = permit;
            let mut graph = state
                .graph
                .lock()
                .map_err(|_| "knowledge graph lock failed".to_owned())?;
            call(&mut graph)
        })
    }
}

#[hxn::methods]
impl GraphBackend {
    pub fn new() -> Self {
        Self {
            state: Arc::new(State {
                graph: Mutex::new(None),
                started: AtomicBool::new(false),
                closing: AtomicBool::new(false),
                pending: AtomicUsize::new(0),
            }),
        }
    }

    pub fn initialize(&self, directory: &str) -> Future<()> {
        if directory.len() > 8192 || directory.contains('\0') {
            return reject("invalid graph directory");
        }
        if self.state.started.swap(true, Ordering::AcqRel) {
            return reject("knowledge graph was already initialized");
        }
        #[cfg(target_family = "wasm")]
        if !directory.is_empty() {
            return reject("use graph snapshots with hxn-file persistence in browser builds");
        }
        let directory = directory.to_owned();
        self.work(move |state| {
            let database = if directory.is_empty() {
                Database::in_memory()
            } else {
                Database::open(std::path::Path::new(&directory)).map_err(|e| e.to_string())?
            };
            let adapter = KnowledgeAdapter::new(database.connect()).map_err(|e| e.to_string())?;
            *state = Some(OpenGraph { adapter, database });
            hxn::log::debug!(target:"hxn.assets", "opened knowledge graph");
            Ok(())
        })
    }

    pub fn apply_json(&self, batch: &str) -> Future<()> {
        if batch.len() > MAX_BATCH {
            return reject("knowledge batch exceeds 1 MiB");
        }
        let batch = batch.to_owned();
        self.work(move |state| {
            let graph = state.as_mut().ok_or("knowledge graph is not open")?;
            graph
                .adapter
                .apply_json(&batch)
                .map_err(|e| e.to_string())?;
            Ok(())
        })
    }

    pub fn query_json(&self, query: &str, parameters: &str) -> Future<String> {
        if query.is_empty() || query.len() > MAX_QUERY || parameters.len() > 262144 {
            return reject("graph query exceeds its input limits");
        }
        let query = query.to_owned();
        let parameters = parameters.to_owned();
        self.work(move |state| {
            let graph = state.as_mut().ok_or("knowledge graph is not open")?;
            let parameters: serde_json::Map<String, Value> =
                serde_json::from_str(&parameters).map_err(|e| e.to_string())?;
            if parameters.len() > 64 {
                return Err("too many graph query parameters".into());
            }
            let parameters: HashMap<String, TypedValue> = parameters
                .into_iter()
                .map(|(key, value)| parameter(&value, 0).map(|value| (key, value)))
                .collect::<Result<_, _>>()?;
            let result = graph
                .adapter
                .connection()
                .query_with_params(&query, parameters)
                .map_err(|e| e.to_string())?;
            if result.num_rows() > 1024 || result.num_columns() > 64 {
                return Err("graph result exceeds its row or column limit".into());
            }
            let columns: Vec<String> = result
                .column_names
                .iter()
                .map(ToString::to_string)
                .collect();
            let types: Vec<String> = result
                .column_types
                .iter()
                .map(|v| v.type_name().into_owned())
                .collect();
            let rows: Vec<Vec<Value>> = result
                .iter_rows()
                .map(|row| row.iter().map(|v| wire(v, 0)).collect())
                .collect::<Result<_, _>>()?;
            let value = json!({"columns":columns,"types":types,"rows":rows});
            let encoded = serde_json::to_string(&value).map_err(|e| e.to_string())?;
            if encoded.len() > MAX_BATCH {
                return Err("graph result exceeds 1 MiB".into());
            }
            Ok(encoded)
        })
    }

    pub fn initialize_snapshot(&self, bytes: &[u8]) -> Future<()> {
        if bytes.len() > 64 * 1024 * 1024 {
            return reject("graph snapshot exceeds 64 MiB");
        }
        if self.state.started.swap(true, Ordering::AcqRel) {
            return reject("knowledge graph was already initialized");
        }
        let bytes = bytes.to_vec();
        self.work(move |state| {
            let database =
                Database::from_snapshot(&bytes, 64 * 1024 * 1024).map_err(|e| e.to_string())?;
            let adapter = KnowledgeAdapter::new(database.connect()).map_err(|e| e.to_string())?;
            *state = Some(OpenGraph { adapter, database });
            Ok(())
        })
    }

    pub fn snapshot(&self) -> Future<Vec<u8>> {
        self.work(move |state| {
            let graph = state.as_ref().ok_or("knowledge graph is not open")?;
            graph
                .database
                .snapshot(64 * 1024 * 1024)
                .map_err(|e| e.to_string())
        })
    }

    pub fn jit_enabled(&self) -> bool {
        hxn_assets_kyugraph::JIT_ENABLED
    }

    pub fn shutdown(&self) -> Future<()> {
        self.state.closing.store(true, Ordering::Release);
        let state = self.state.clone();
        background(move || {
            let mut graph = state
                .graph
                .lock()
                .map_err(|_| "knowledge graph lock failed".to_owned())?;
            if let Some(open) = graph.take() {
                open.database.checkpoint().map_err(|e| e.to_string())?;
                drop(open);
            }
            Ok::<_, String>(())
        })
    }
}

fn wire(value: &TypedValue, depth: usize) -> Result<Value, String> {
    if depth > 32 {
        return Err("graph value nesting exceeds its limit".into());
    }
    let (kind, data) = match value {
        TypedValue::Null => ("null", Value::Null),
        TypedValue::Bool(v) => ("bool", Value::Bool(*v)),
        TypedValue::Int8(v) => ("int", Value::from(*v)),
        TypedValue::Int16(v) => ("int", Value::from(*v)),
        TypedValue::Int32(v) => ("int", Value::from(*v)),
        TypedValue::Int64(v) | TypedValue::Serial(v) => ("int64", Value::from(v.to_string())),
        TypedValue::Int128(v) => ("integer", Value::from(v.to_string())),
        TypedValue::UInt8(v) => ("int", Value::from(*v)),
        TypedValue::UInt16(v) => ("int", Value::from(*v)),
        TypedValue::UInt32(v) => ("int64", Value::from(v.to_string())),
        TypedValue::UInt64(v) => ("integer", Value::from(v.to_string())),
        TypedValue::Float(v) => (
            "float",
            Value::Number(
                serde_json::Number::from_f64(*v as f64).ok_or("non-finite graph result")?,
            ),
        ),
        TypedValue::Double(v) => (
            "float",
            Value::Number(serde_json::Number::from_f64(*v).ok_or("non-finite graph result")?),
        ),
        TypedValue::String(v) | TypedValue::Uuid(v) => {
            if v.len() > 65536 {
                return Err("graph result string exceeds 64 KiB".into());
            }
            ("string", Value::from(v.to_string()))
        }
        TypedValue::List(values) | TypedValue::Array(values) => {
            if values.len() > 1024 {
                return Err("graph result list exceeds its limit".into());
            }
            (
                "list",
                Value::Array(
                    values
                        .iter()
                        .map(|v| wire(v, depth + 1))
                        .collect::<Result<_, _>>()?,
                ),
            )
        }
        TypedValue::Struct(values) => {
            if values.len() > 64 {
                return Err("graph result struct exceeds its limit".into());
            }
            let mut fields = serde_json::Map::new();
            for (name, value) in values {
                fields.insert(name.to_string(), wire(value, depth + 1)?);
            }
            ("object", Value::Object(fields))
        }
        TypedValue::Map(values) => {
            if values.len() > 1024 {
                return Err("graph result map exceeds its limit".into());
            }
            let mut rows = Vec::new();
            for (key, value) in values {
                rows.push(json!([wire(key, depth + 1)?, wire(value, depth + 1)?]));
            }
            ("map", Value::Array(rows))
        }
        TypedValue::Blob(value) => {
            if value.len() > 65536 {
                return Err("graph result blob exceeds its limit".into());
            }
            (
                "blob",
                Value::from(value.iter().map(|b| format!("{b:02x}")).collect::<String>()),
            )
        }
        TypedValue::Date(v)
        | TypedValue::Timestamp(v)
        | TypedValue::TimestampSec(v)
        | TypedValue::TimestampMs(v)
        | TypedValue::TimestampNs(v)
        | TypedValue::TimestampTz(v) => ("int64", Value::from(v.to_string())),
        TypedValue::Interval(v) => (
            "object",
            json!({"months":["int",v.months],"days":["int",v.days],"micros":["int64",v.micros.to_string()]}),
        ),
        TypedValue::InternalId(v) => (
            "object",
            json!({"table":["integer",v.table_id.to_string()],"offset":["integer",v.offset.to_string()]}),
        ),
    };
    Ok(json!([kind, data]))
}

fn parameter(value: &Value, depth: usize) -> Result<TypedValue, String> {
    if depth > 32 {
        return Err("graph parameter nesting exceeds its limit".into());
    }
    let pair = value
        .as_array()
        .filter(|p| p.len() == 2)
        .ok_or("invalid graph parameter encoding")?;
    let kind = pair[0].as_str().ok_or("invalid graph parameter kind")?;
    let data = &pair[1];
    let bad = || "invalid graph parameter value".to_owned();
    match kind {
        "null" if data.is_null() => Ok(TypedValue::Null),
        "bool" => data.as_bool().map(TypedValue::Bool).ok_or_else(bad),
        "int" => data.as_i64().map(TypedValue::Int64).ok_or_else(bad),
        "int64" => data
            .as_str()
            .ok_or_else(bad)?
            .parse::<i64>()
            .map(TypedValue::Int64)
            .map_err(|_| bad()),
        "float" => data
            .as_f64()
            .filter(|v| v.is_finite())
            .map(TypedValue::Double)
            .ok_or_else(bad),
        "string" => {
            let value = data.as_str().filter(|v| v.len() <= 65536).ok_or_else(bad)?;
            Ok(TypedValue::String(value.into()))
        }
        "list" => {
            let values = data
                .as_array()
                .filter(|v| v.len() <= 1024)
                .ok_or_else(bad)?;
            Ok(TypedValue::List(
                values
                    .iter()
                    .map(|v| parameter(v, depth + 1))
                    .collect::<Result<_, _>>()?,
            ))
        }
        "object" => {
            let fields = data.as_object().filter(|v| v.len() <= 64).ok_or_else(bad)?;
            let mut values = Vec::new();
            for (name, value) in fields {
                values.push((name.as_str().into(), parameter(value, depth + 1)?));
            }
            Ok(TypedValue::Struct(values))
        }
        "blob" => {
            let text = data
                .as_str()
                .filter(|v| v.len() <= 131072 && v.len() % 2 == 0)
                .ok_or_else(bad)?;
            let mut bytes = Vec::new();
            for pair in text.as_bytes().as_chunks::<2>().0 {
                let text = std::str::from_utf8(pair).map_err(|_| bad())?;
                bytes.push(u8::from_str_radix(text, 16).map_err(|_| bad())?);
            }
            Ok(TypedValue::Blob(bytes))
        }
        _ => Err(bad()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn take<T: Send + 'static>(future: Future<T>) -> Result<T, hxn_future::Failure> {
        assert_ne!(
            future.wait(Some(Duration::from_secs(10))),
            hxn_future::State::Pending
        );
        future.take()
    }

    #[test]
    fn concurrent_queries_own_inputs_and_reuse_workers() {
        let graph = GraphBackend::new();
        take(graph.initialize("")).unwrap();
        for round in 0..20 {
            let requests: Vec<_> = (0..8)
                .map(|index| {
                    let parameters = json!({"value":["int",round * 8 + index]}).to_string();
                    graph.query_json("RETURN $value AS value", &parameters)
                })
                .collect();
            for (index, request) in requests.into_iter().enumerate() {
                let value: Value = serde_json::from_str(&take(request).unwrap()).unwrap();
                assert_eq!(
                    value["rows"][0][0],
                    json!(["int64", (round * 8 + index as i32).to_string()])
                );
            }
        }
        take(graph.shutdown()).unwrap();
        assert!(take(graph.query_json("RETURN 1", "{}")).is_err());
    }

    #[test]
    fn snapshot_input_is_owned_and_limits_reject() {
        let graph = GraphBackend::new();
        take(graph.initialize("")).unwrap();
        take(graph.query_json("CREATE NODE TABLE Item (id INT64, PRIMARY KEY(id))", "{}")).unwrap();
        take(graph.query_json("CREATE (:Item {id:9007199254740993})", "{}")).unwrap();
        let mut bytes = take(graph.snapshot()).unwrap();
        take(graph.shutdown()).unwrap();
        let restored = GraphBackend::new();
        let loading = restored.initialize_snapshot(&bytes);
        bytes.fill(0);
        take(loading).unwrap();
        let value: Value = serde_json::from_str(
            &take(restored.query_json("MATCH (n:Item) RETURN n.id", "{}")).unwrap(),
        )
        .unwrap();
        assert_eq!(value["rows"][0][0], json!(["int64", "9007199254740993"]));
        assert!(take(restored.query_json(&"x".repeat(MAX_QUERY + 1), "{}")).is_err());
        assert!(take(restored.query_json("RETURN 1", &"x".repeat(262145))).is_err());
        assert!(take(restored.apply_json(&"x".repeat(MAX_BATCH + 1))).is_err());
        take(restored.shutdown()).unwrap();
    }
}
