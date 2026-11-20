//! Projection core for the installed Haxe knowledge API.
//!
//! The caller owns scheduling, authorization and the database connection. This
//! crate supplies graph updates; the hxn-assets binding owns its scheduling.
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::error::Error;
use std::fmt;

use kyu_graph::DeltaBatchBuilder;
pub use kyu_graph::{Connection, Database, QueryResult, TypedValue};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

type Result<T> = std::result::Result<T, KnowledgeError>;

#[derive(Debug)]
pub struct KnowledgeError(String);
impl fmt::Display for KnowledgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl Error for KnowledgeError {}
impl From<kyu_graph::KyuError> for KnowledgeError {
    fn from(value: kyu_graph::KyuError) -> Self {
        Self(value.to_string())
    }
}
impl From<serde_json::Error> for KnowledgeError {
    fn from(value: serde_json::Error) -> Self {
        Self(value.to_string())
    }
}
fn require(condition: bool, message: &str) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(KnowledgeError(message.into()))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Fact {
    name: String,
    kind: String,
    nullable: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Relation {
    name: String,
    target: String,
    many: bool,
    nullable: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Schema {
    name: String,
    version: u32,
    identity: String,
    facts: Vec<Fact>,
    relations: Vec<Relation>,
    spatial: Option<SpatialSelection>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct SpatialSelection {
    relation: String,
    units: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Bounds {
    world: String,
    units: String,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AssetOrigin {
    address: String,
    content_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Node {
    schema: Schema,
    id: String,
    facts: BTreeMap<String, Value>,
    links: Vec<Vec<String>>,
    bounds: Option<Bounds>,
    asset: Option<AssetOrigin>,
    deleted: bool,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Batch {
    version: u32,
    namespace: String,
    source: String,
    revision: u32,
    nodes: Vec<Node>,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.as_bytes()[0].is_ascii_alphabetic()
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
}
fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 256 && !value.contains('\0')
}
fn quote(value: &str) -> String {
    format!("`{value}`")
}
fn key(namespace: &str, id: &str) -> String {
    serde_json::to_string(&(namespace, id)).expect("string tuple serializes")
}
fn params(
    values: impl IntoIterator<Item = (&'static str, TypedValue)>,
) -> HashMap<String, TypedValue> {
    values
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect()
}
fn string(value: impl Into<String>) -> TypedValue {
    TypedValue::from(Value::String(value.into()))
}
fn relation_table(source: &str, relation: &Relation) -> String {
    format!("{}__{}__{}", source, relation.name, relation.target)
}
fn scalar_type(kind: &str) -> Option<&'static str> {
    match kind {
        "string" => Some("STRING"),
        "int" => Some("INT64"),
        "float" => Some("DOUBLE"),
        "bool" => Some("BOOL"),
        _ => None,
    }
}
fn sql_type(kind: &str) -> Option<String> {
    if let Some(child) = kind.strip_suffix("[]") {
        scalar_type(child).map(|_| "STRING".to_owned())
    } else {
        scalar_type(kind).map(str::to_owned)
    }
}
fn valid_value(value: &Value, kind: &str, nullable: bool) -> bool {
    if value.is_null() {
        return nullable;
    }
    if let Some(child) = kind.strip_suffix("[]") {
        return value.as_array().is_some_and(|values| {
            values.len() <= 1024 && values.iter().all(|value| valid_value(value, child, false))
        });
    }
    match kind {
        "string" => value.as_str().is_some_and(|value| value.len() <= 65536),
        "int" => value
            .as_i64()
            .is_some_and(|value| i32::try_from(value).is_ok()),
        "float" => value.as_f64().is_some_and(f64::is_finite),
        "bool" => value.is_boolean(),
        _ => false,
    }
}
fn validate(batch: &Batch) -> Result<()> {
    require(
        batch.version == 1 && valid_id(&batch.namespace) && valid_id(&batch.source),
        "invalid knowledge protocol or scope",
    )?;
    require(
        batch.revision > 0 && batch.revision <= (i32::MAX as u32) && batch.nodes.len() <= 256,
        "invalid knowledge revision or node count",
    )?;
    let mut keys = BTreeSet::new();
    for node in &batch.nodes {
        let schema = &node.schema;
        require(
            valid_name(&schema.name) && valid_name(&schema.identity) && valid_id(&node.id),
            "invalid knowledge type or identity",
        )?;
        require(
            schema.version > 0 && schema.facts.len() + schema.relations.len() <= 64,
            "invalid knowledge schema",
        )?;
        require(
            keys.insert((&schema.name, &node.id)),
            "duplicate knowledge identity in batch",
        )?;
        let mut names = BTreeSet::from([schema.identity.as_str()]);
        for fact in &schema.facts {
            require(
                valid_name(&fact.name)
                    && names.insert(&fact.name)
                    && sql_type(&fact.kind).is_some(),
                "invalid knowledge fact schema",
            )?;
            if !node.deleted {
                require(
                    node.facts
                        .get(&fact.name)
                        .is_some_and(|value| valid_value(value, &fact.kind, fact.nullable)),
                    "invalid knowledge fact value",
                )?;
            }
        }
        require(
            (node.deleted && node.links.is_empty() && node.facts.is_empty())
                || (!node.deleted
                    && node.links.len() == schema.relations.len()
                    && node.facts.len() == schema.facts.len()),
            "knowledge payload differs from schema",
        )?;
        for (index, relation) in schema.relations.iter().enumerate() {
            require(
                valid_name(&relation.name)
                    && valid_name(&relation.target)
                    && names.insert(&relation.name),
                "invalid knowledge relationship schema",
            )?;
            if !node.deleted {
                let links = &node.links[index];
                require(
                    links.len() <= 1024
                        && (relation.many || links.len() <= 1)
                        && (relation.many || relation.nullable || links.len() == 1),
                    "invalid relationship cardinality",
                )?;
                let mut unique = BTreeSet::new();
                require(
                    links.iter().all(|id| valid_id(id) && unique.insert(id)),
                    "invalid or duplicated relationship target",
                )?;
            }
        }
        require(
            (node.deleted && node.bounds.is_none())
                || (!node.deleted && schema.spatial.is_some() == node.bounds.is_some()),
            "invalid knowledge spatial selection",
        )?;
        if let Some(selection) = &schema.spatial {
            let relation = schema
                .relations
                .iter()
                .find(|relation| relation.name == selection.relation);
            require(
                valid_id(&selection.units)
                    && relation.is_some_and(|relation| !relation.many && !relation.nullable),
                "invalid spatial schema relationship",
            )?;
        }
        if let Some(bounds) = &node.bounds {
            let selection = schema.spatial.as_ref().expect("validated spatial schema");
            let index = schema
                .relations
                .iter()
                .position(|relation| relation.name == selection.relation)
                .expect("validated spatial relation");
            require(
                bounds.units == selection.units && node.links[index][0] == bounds.world,
                "spatial context differs from relationship schema",
            )?;
            require(
                valid_id(&bounds.world) && valid_id(&bounds.units),
                "invalid spatial world or units",
            )?;
            require(
                [
                    bounds.min_x,
                    bounds.min_y,
                    bounds.min_z,
                    bounds.max_x,
                    bounds.max_y,
                    bounds.max_z,
                ]
                .into_iter()
                .all(f64::is_finite)
                    && bounds.min_x <= bounds.max_x
                    && bounds.min_y <= bounds.max_y
                    && bounds.min_z <= bounds.max_z,
                "invalid spatial bounds",
            )?;
        }
        if let Some(asset) = &node.asset {
            require(valid_id(&asset.address), "invalid asset provenance address")?;
            if let Some(content) = &asset.content_id {
                require(
                    content.len() == 71
                        && content.starts_with("sha256:")
                        && content[7..]
                            .bytes()
                            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
                    "invalid asset content identity",
                )?;
            }
        }
    }
    Ok(())
}

/// The outcome of a source revision, including safe replay and stale delivery.
#[derive(Debug, PartialEq, Eq)]
pub enum ApplyOutcome {
    Applied,
    Replayed,
    Stale,
}

/// A single-writer adapter over an application-owned native KyuGraph connection.
pub struct KnowledgeAdapter {
    connection: Connection,
}
impl KnowledgeAdapter {
    pub fn new(connection: Connection) -> Result<Self> {
        for (name, ddl) in [
            (
                "_HxnKnowledgeSchema",
                "CREATE NODE TABLE `_HxnKnowledgeSchema` (name STRING, definition STRING, PRIMARY KEY (name))",
            ),
            (
                "_HxnKnowledgeSource",
                "CREATE NODE TABLE `_HxnKnowledgeSource` (key STRING, revision INT64, digest STRING, PRIMARY KEY (key))",
            ),
        ] {
            match connection.query(ddl) {
                Ok(_) => {}
                Err(
                    kyu_graph::KyuError::Catalog(message) | kyu_graph::KyuError::Binder(message),
                ) if message == format!("table '{name}' already exists") => {}
                Err(error) => {
                    return Err(error.into());
                }
            }
        }
        connection.query("MATCH (s:`_HxnKnowledgeSchema`) RETURN s.name, s.definition LIMIT 0")?;
        connection
            .query("MATCH (s:`_HxnKnowledgeSource`) RETURN s.key, s.revision, s.digest LIMIT 0")?;
        Ok(Self { connection })
    }

    /// Query with KyuGraph's parameter bindings on the same database.
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// Validate before mutation, then apply complete selected snapshots in one delta.
    /// Source watermarks and tombstones survive connection/database restarts.
    pub fn apply_json(&mut self, json: &str) -> Result<ApplyOutcome> {
        require(json.len() <= 1048576, "knowledge batch exceeds 1 MiB")?;
        let batch: Batch = serde_json::from_str(json)?;
        validate(&batch)?;
        let digest = format!("{:x}", Sha256::digest(serde_json::to_vec(&batch)?));
        let owner = key(&batch.namespace, &batch.source);
        let previous = self.connection.query_with_params(
            "MATCH (s:`_HxnKnowledgeSource`) WHERE s.key = $key RETURN s.revision, s.digest",
            params([("key", string(&owner))]),
        )?;
        if previous.num_rows() > 0 {
            let TypedValue::Int64(revision) = previous.row(0)[0] else {
                return Err(KnowledgeError("invalid stored source revision".into()));
            };
            if i64::from(batch.revision) < revision {
                return Ok(ApplyOutcome::Stale);
            }
            if i64::from(batch.revision) == revision {
                require(
                    previous.row(0)[1] == string(&digest),
                    "knowledge revision reused with different data",
                )?;
                return Ok(ApplyOutcome::Replayed);
            }
        }
        let mut schemas = BTreeMap::<String, Schema>::new();
        let known = self
            .connection
            .query("MATCH (s:`_HxnKnowledgeSchema`) RETURN s.definition")?;
        for row in known.iter_rows() {
            let TypedValue::String(value) = &row[0] else {
                return Err(KnowledgeError("invalid stored schema".into()));
            };
            let schema: Schema = serde_json::from_str(value)?;
            schemas.insert(schema.name.clone(), schema);
        }
        let mut new = BTreeMap::new();
        for node in &batch.nodes {
            let schema = &node.schema;
            if let Some(previous) = schemas.get(&schema.name) {
                require(
                    previous == schema,
                    "knowledge schema changed without migration",
                )?;
            } else {
                schemas.insert(schema.name.clone(), schema.clone());
                new.insert(schema.name.clone(), schema.clone());
            }
        }
        for schema in schemas.values() {
            for relation in &schema.relations {
                require(
                    schemas.contains_key(&relation.target),
                    "unknown relationship schema; publish its declaration first",
                )?;
            }
        }
        // DDL may register an unused schema after failure; data and watermark updates follow validation.
        for schema in new.values() {
            self.create_node_table(schema)?;
        }
        for schema in new.values() {
            self.create_relation_tables(schema)?;
        }
        for schema in new.values() {
            self.connection.query_with_params(
                "CREATE (s:`_HxnKnowledgeSchema` {name:$name, definition:$definition})",
                params([
                    ("name", string(&schema.name)),
                    ("definition", string(serde_json::to_string(schema)?)),
                ]),
            )?;
        }

        let mut delta = DeltaBatchBuilder::new(owner, batch.revision.into());
        let mut old_links = Vec::new();
        for node in &batch.nodes {
            let schema = &node.schema;
            let node_key = key(&batch.namespace, &node.id);
            let previous = self.connection.query_with_params(
                &format!(
                    "MATCH (n:{}) WHERE n._hxn_key = $key RETURN n._hxn_source, n._hxn_links",
                    quote(&schema.name)
                ),
                params([("key", string(&node_key))]),
            )?;
            if previous.num_rows() > 0 {
                require(
                    previous.row(0)[0] == string(&batch.source),
                    "knowledge entity belongs to another source",
                )?;
                let TypedValue::String(json) = &previous.row(0)[1] else {
                    return Err(KnowledgeError("invalid stored relationships".into()));
                };
                old_links.push(serde_json::from_str::<Vec<Vec<String>>>(json)?);
            } else {
                old_links.push(Vec::new());
            }
            let mut properties = vec![
                ("_hxn_namespace".into(), string(&batch.namespace)),
                ("_hxn_source".into(), string(&batch.source)),
                (
                    "_hxn_revision".into(),
                    TypedValue::Int64(batch.revision.into()),
                ),
                ("_hxn_deleted".into(), TypedValue::Bool(node.deleted)),
                (
                    "_hxn_links".into(),
                    string(serde_json::to_string(&node.links)?),
                ),
                (schema.identity.clone(), string(&node.id)),
                (
                    "_hxn_asset_address".into(),
                    node.asset
                        .as_ref()
                        .map(|asset| string(&asset.address))
                        .unwrap_or(TypedValue::Null),
                ),
                (
                    "_hxn_content_id".into(),
                    node.asset
                        .as_ref()
                        .and_then(|asset| asset.content_id.as_ref())
                        .map(string)
                        .unwrap_or(TypedValue::Null),
                ),
            ];
            for fact in &schema.facts {
                let value = node.facts.get(&fact.name).cloned().unwrap_or(Value::Null);
                properties.push((fact.name.clone(), typed_value(value, &fact.kind)));
            }
            if schema.spatial.is_some() {
                let bounds = node.bounds.as_ref();
                properties.push((
                    "_hxn_world".into(),
                    bounds.map(|b| string(&b.world)).unwrap_or(TypedValue::Null),
                ));
                properties.push((
                    "_hxn_units".into(),
                    bounds.map(|b| string(&b.units)).unwrap_or(TypedValue::Null),
                ));
                for (name, value) in [
                    ("_hxn_min_x", bounds.map(|b| b.min_x)),
                    ("_hxn_min_y", bounds.map(|b| b.min_y)),
                    ("_hxn_min_z", bounds.map(|b| b.min_z)),
                    ("_hxn_max_x", bounds.map(|b| b.max_x)),
                    ("_hxn_max_y", bounds.map(|b| b.max_y)),
                    ("_hxn_max_z", bounds.map(|b| b.max_z)),
                ] {
                    properties.push((
                        name.into(),
                        value.map(TypedValue::Double).unwrap_or(TypedValue::Null),
                    ));
                }
            }
            delta = delta.upsert_node(&schema.name, node_key, vec![], properties);
        }
        for (node, old) in batch.nodes.iter().zip(old_links) {
            for (relation, targets) in node.schema.relations.iter().zip(old) {
                for target in targets {
                    delta = delta.delete_edge(
                        &node.schema.name,
                        key(&batch.namespace, &node.id),
                        relation_table(&node.schema.name, relation),
                        &relation.target,
                        key(&batch.namespace, &target),
                    );
                }
            }
            if !node.deleted {
                for (relation, targets) in node.schema.relations.iter().zip(&node.links) {
                    for target in targets {
                        delta = delta.upsert_edge(
                            &node.schema.name,
                            key(&batch.namespace, &node.id),
                            relation_table(&node.schema.name, relation),
                            &relation.target,
                            key(&batch.namespace, target),
                            [
                                ("_hxn_source", string(&batch.source)),
                                ("_hxn_revision", TypedValue::Int64(batch.revision.into())),
                            ],
                        );
                    }
                }
            }
        }
        delta = delta.upsert_node(
            "_HxnKnowledgeSource",
            key(&batch.namespace, &batch.source),
            vec![],
            [
                ("revision", TypedValue::Int64(batch.revision.into())),
                ("digest", string(digest)),
            ],
        );
        self.connection.apply_delta(delta.build())?;
        Ok(ApplyOutcome::Applied)
    }

    fn create_node_table(&self, schema: &Schema) -> Result<()> {
        let mut fields = vec![
            "_hxn_key STRING".into(),
            "_hxn_namespace STRING".into(),
            "_hxn_source STRING".into(),
            "_hxn_revision INT64".into(),
            "_hxn_deleted BOOL".into(),
            "_hxn_links STRING".into(),
            "_hxn_asset_address STRING".into(),
            "_hxn_content_id STRING".into(),
            format!("{} STRING", quote(&schema.identity)),
        ];
        for fact in &schema.facts {
            fields.push(format!(
                "{} {}",
                quote(&fact.name),
                sql_type(&fact.kind).expect("validated fact type")
            ));
        }
        if schema.spatial.is_some() {
            fields.extend(
                [
                    "_hxn_world STRING",
                    "_hxn_units STRING",
                    "_hxn_min_x DOUBLE",
                    "_hxn_min_y DOUBLE",
                    "_hxn_min_z DOUBLE",
                    "_hxn_max_x DOUBLE",
                    "_hxn_max_y DOUBLE",
                    "_hxn_max_z DOUBLE",
                ]
                .map(str::to_owned),
            );
        }
        fields.push("PRIMARY KEY (_hxn_key)".into());
        self.connection.query(&format!(
            "CREATE NODE TABLE {} ({})",
            quote(&schema.name),
            fields.join(", ")
        ))?;
        Ok(())
    }
    fn create_relation_tables(&self, schema: &Schema) -> Result<()> {
        for relation in &schema.relations {
            self.connection.query(&format!(
                "CREATE REL TABLE {} (FROM {} TO {}, _hxn_source STRING, _hxn_revision INT64)",
                quote(&relation_table(&schema.name, relation)),
                quote(&schema.name),
                quote(&relation.target)
            ))?;
        }
        Ok(())
    }
}

fn typed_value(value: Value, kind: &str) -> TypedValue {
    if value.is_null() {
        return TypedValue::Null;
    }
    // KyuGraph 0.4 DDL cannot declare list columns; preserve scalar arrays as JSON text.
    if kind.ends_with("[]") {
        return string(serde_json::to_string(&value).expect("validated scalar array"));
    }
    if kind == "float" {
        return TypedValue::Double(value.as_f64().expect("validated float"));
    }
    TypedValue::from(value)
}

/// Whether this build enables native expression compilation.
pub const JIT_ENABLED: bool = cfg!(feature = "jit");
