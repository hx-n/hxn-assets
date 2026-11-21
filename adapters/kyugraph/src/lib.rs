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
    /// The facts and relationships a partial snapshot selects; absent for a complete one.
    /// Skipped when absent so a complete batch serializes, and digests, as format version 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fields: Option<Vec<String>>,
}
impl Node {
    fn selects(&self, name: &str) -> bool {
        self.fields
            .as_ref()
            .is_none_or(|fields| fields.iter().any(|field| field == name))
    }
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
        (batch.version == 1 || batch.version == 2)
            && valid_id(&batch.namespace)
            && valid_id(&batch.source),
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
        if let Some(fields) = &node.fields {
            let mut unique = BTreeSet::new();
            require(
                batch.version == 2
                    && !node.deleted
                    && !fields.is_empty()
                    && fields.iter().all(|field| {
                        unique.insert(field)
                            && (schema.facts.iter().any(|fact| &fact.name == field)
                                || schema
                                    .relations
                                    .iter()
                                    .any(|relation| &relation.name == field))
                    }),
                "invalid partial knowledge selection",
            )?;
        }
        let mut names = BTreeSet::from([schema.identity.as_str()]);
        for fact in &schema.facts {
            require(
                valid_name(&fact.name)
                    && names.insert(&fact.name)
                    && sql_type(&fact.kind).is_some(),
                "invalid knowledge fact schema",
            )?;
            if !node.deleted && node.selects(&fact.name) {
                require(
                    node.facts
                        .get(&fact.name)
                        .is_some_and(|value| valid_value(value, &fact.kind, fact.nullable)),
                    "invalid knowledge fact value",
                )?;
            }
        }
        let selected_facts = schema
            .facts
            .iter()
            .filter(|fact| node.selects(&fact.name))
            .count();
        require(
            (node.deleted && node.links.is_empty() && node.facts.is_empty())
                || (!node.deleted
                    && node.links.len() == schema.relations.len()
                    && node.facts.len() == selected_facts),
            "knowledge payload differs from schema",
        )?;
        for (index, relation) in schema.relations.iter().enumerate() {
            require(
                valid_name(&relation.name)
                    && valid_name(&relation.target)
                    && names.insert(&relation.name),
                "invalid knowledge relationship schema",
            )?;
            if !node.deleted && !node.selects(&relation.name) {
                require(
                    node.links[index].is_empty(),
                    "unselected relationship carries targets",
                )?;
            } else if !node.deleted {
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
        let spatial_selected = schema
            .spatial
            .as_ref()
            .is_some_and(|selection| node.selects(&selection.relation));
        require(
            (node.deleted && node.bounds.is_none())
                || (!node.deleted && spatial_selected == node.bounds.is_some()),
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

/// What the graph holds for an entity a batch names.
struct Stored {
    source: String,
    links: Vec<Vec<String>>,
    deleted: bool,
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

        // One lookup per semantic type: the owner, outgoing links and tombstone of each entity named.
        let mut by_schema = BTreeMap::<&str, Vec<Value>>::new();
        for node in &batch.nodes {
            by_schema
                .entry(&node.schema.name)
                .or_default()
                .push(Value::String(key(&batch.namespace, &node.id)));
        }
        let mut stored = HashMap::<(String, String), Stored>::new();
        for (name, keys) in by_schema {
            let found = self.connection.query_with_params(
                &format!(
                    "MATCH (n:{}) WHERE n._hxn_key IN $keys RETURN n._hxn_key, n._hxn_source, n._hxn_links, n._hxn_deleted",
                    quote(name)
                ),
                params([("keys", TypedValue::from(Value::Array(keys)))]),
            )?;
            for row in found.iter_rows() {
                let (
                    TypedValue::String(node_key),
                    TypedValue::String(source),
                    TypedValue::String(links),
                    TypedValue::Bool(deleted),
                ) = (&row[0], &row[1], &row[2], &row[3])
                else {
                    return Err(KnowledgeError("invalid stored knowledge entity".into()));
                };
                stored.insert(
                    (name.to_owned(), node_key.to_string()),
                    Stored {
                        source: source.to_string(),
                        links: serde_json::from_str(links)?,
                        deleted: *deleted,
                    },
                );
            }
        }

        let mut delta = DeltaBatchBuilder::new(owner, batch.revision.into());
        for node in &batch.nodes {
            let schema = &node.schema;
            let node_key = key(&batch.namespace, &node.id);
            let previous = stored.get(&(schema.name.clone(), node_key.clone()));
            if let Some(previous) = previous {
                require(
                    previous.source == batch.source,
                    "knowledge entity belongs to another source",
                )?;
            }
            let partial = node.fields.is_some();
            require(
                !partial || previous.is_some_and(|previous| !previous.deleted),
                "a partial knowledge snapshot needs an earlier complete snapshot of the entity",
            )?;
            let old_links = previous
                .map(|previous| previous.links.as_slice())
                .unwrap_or(&[]);
            // A partial snapshot keeps the stored targets of the relationships it does not select.
            let links: Vec<Vec<String>> = if node.deleted {
                Vec::new()
            } else {
                schema
                    .relations
                    .iter()
                    .enumerate()
                    .map(|(index, relation)| {
                        if node.selects(&relation.name) {
                            node.links[index].clone()
                        } else {
                            old_links.get(index).cloned().unwrap_or_default()
                        }
                    })
                    .collect()
            };
            let mut properties = vec![
                ("_hxn_namespace".into(), string(&batch.namespace)),
                ("_hxn_source".into(), string(&batch.source)),
                (
                    "_hxn_revision".into(),
                    TypedValue::Int64(batch.revision.into()),
                ),
                ("_hxn_deleted".into(), TypedValue::Bool(node.deleted)),
                ("_hxn_links".into(), string(serde_json::to_string(&links)?)),
                (schema.identity.clone(), string(&node.id)),
            ];
            // A partial snapshot without provenance keeps the stored provenance.
            if !partial || node.asset.is_some() {
                properties.push((
                    "_hxn_asset_address".into(),
                    node.asset
                        .as_ref()
                        .map(|asset| string(&asset.address))
                        .unwrap_or(TypedValue::Null),
                ));
                properties.push((
                    "_hxn_content_id".into(),
                    node.asset
                        .as_ref()
                        .and_then(|asset| asset.content_id.as_ref())
                        .map(string)
                        .unwrap_or(TypedValue::Null),
                ));
            }
            // An upsert names only the columns it changes; KyuGraph keeps the rest.
            for fact in schema.facts.iter().filter(|fact| node.selects(&fact.name)) {
                let value = node.facts.get(&fact.name).cloned().unwrap_or(Value::Null);
                properties.push((fact.name.clone(), typed_value(value, &fact.kind)));
            }
            if schema
                .spatial
                .as_ref()
                .is_some_and(|selection| node.selects(&selection.relation))
            {
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
            delta = delta.upsert_node(&schema.name, node_key.clone(), vec![], properties);
            // Only the edges that change: removed targets are deleted and new ones added.
            for (index, relation) in schema.relations.iter().enumerate() {
                let before: BTreeSet<&String> = old_links
                    .get(index)
                    .map(|targets| targets.iter().collect())
                    .unwrap_or_default();
                let after: BTreeSet<&String> = links
                    .get(index)
                    .map(|targets| targets.iter().collect())
                    .unwrap_or_default();
                for target in before.difference(&after) {
                    delta = delta.delete_edge(
                        &schema.name,
                        node_key.clone(),
                        relation_table(&schema.name, relation),
                        &relation.target,
                        key(&batch.namespace, target),
                    );
                }
                for target in after.difference(&before) {
                    delta = delta.upsert_edge(
                        &schema.name,
                        node_key.clone(),
                        relation_table(&schema.name, relation),
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn schemas() -> (Value, Value, Value) {
        let lore = json!({"name":"Lore","version":1,"identity":"id","facts":[{"name":"title","kind":"string","nullable":false}],"relations":[],"spatial":null});
        let world = json!({"name":"World","version":1,"identity":"id","facts":[],"relations":[],"spatial":null});
        let npc = json!({"name":"Npc","version":1,"identity":"id",
            "facts":[{"name":"goal","kind":"string","nullable":false},{"name":"name","kind":"string","nullable":false}],
            "relations":[{"name":"KNOWS","target":"Lore","many":true,"nullable":false},{"name":"IN_WORLD","target":"World","many":false,"nullable":false}],
            "spatial":{"relation":"IN_WORLD","units":"metre"}});
        (lore, world, npc)
    }

    fn bounds(world: &str, x: f64) -> Value {
        json!({"world":world,"units":"metre","minX":x,"minY":0.0,"minZ":0.0,"maxX":x,"maxY":0.0,"maxZ":0.0})
    }

    fn node(schema: &Value, id: &str, facts: Value, links: Value, bounds: Value) -> Value {
        json!({"schema":schema,"id":id,"facts":facts,"links":links,"bounds":bounds,"asset":null,"deleted":false})
    }

    fn batch(version: u32, revision: u32, nodes: Vec<Value>) -> String {
        json!({"version":version,"namespace":"campaign","source":"game","revision":revision,"nodes":nodes}).to_string()
    }

    fn adapter() -> (Database, KnowledgeAdapter) {
        let database = Database::in_memory();
        let adapter = KnowledgeAdapter::new(database.connect()).expect("adapter");
        (database, adapter)
    }

    fn rows(adapter: &KnowledgeAdapter, query: &str) -> Vec<Vec<TypedValue>> {
        let result = adapter.connection().query(query).expect("query");
        result.iter_rows().map(|row| row.to_vec()).collect()
    }

    /// Lore a and b, worlds north and south, and Npc sage knowing a in north.
    fn seeded() -> (Database, KnowledgeAdapter, Value) {
        let (lore, world, npc) = schemas();
        let (database, mut adapter) = adapter();
        let first = batch(
            1,
            1,
            vec![
                node(&lore, "a", json!({"title":"A"}), json!([]), Value::Null),
                node(&lore, "b", json!({"title":"B"}), json!([]), Value::Null),
                node(&world, "north", json!({}), json!([]), Value::Null),
                node(&world, "south", json!({}), json!([]), Value::Null),
                node(
                    &npc,
                    "sage",
                    json!({"goal":"guard","name":"Mira"}),
                    json!([["a"], ["north"]]),
                    bounds("north", 1.0),
                ),
            ],
        );
        assert_eq!(
            adapter.apply_json(&first).expect("seed"),
            ApplyOutcome::Applied
        );
        (database, adapter, npc)
    }

    fn partial(
        npc: &Value,
        revision: u32,
        facts: Value,
        links: Value,
        bounds: Value,
        fields: Value,
    ) -> String {
        let mut value = node(npc, "sage", facts, links, bounds);
        value["fields"] = fields;
        batch(2, revision, vec![value])
    }

    #[test]
    fn partial_snapshot_changes_only_selected_facts() {
        let (_database, mut adapter, npc) = seeded();
        let update = partial(
            &npc,
            2,
            json!({"goal":"travel"}),
            json!([[], []]),
            Value::Null,
            json!(["goal"]),
        );
        assert_eq!(
            adapter.apply_json(&update).expect("partial"),
            ApplyOutcome::Applied
        );
        let row = &rows(
            &adapter,
            "MATCH (n:Npc) RETURN n.goal, n.name, n._hxn_revision, n._hxn_min_x",
        )[0];
        assert_eq!(row[0], string("travel"));
        assert_eq!(row[1], string("Mira"));
        assert_eq!(row[2], TypedValue::Int64(2));
        assert_eq!(row[3], TypedValue::Double(1.0));
        // The unselected relationship keeps its edge.
        assert_eq!(
            rows(
                &adapter,
                "MATCH (n:Npc)-[:Npc__KNOWS__Lore]->(l:Lore) RETURN l.id"
            )
            .len(),
            1
        );
        assert_eq!(
            adapter.apply_json(&update).expect("replay"),
            ApplyOutcome::Replayed
        );
    }

    #[test]
    fn relationship_updates_touch_only_changed_edges() {
        let (_database, mut adapter, npc) = seeded();
        let known = |adapter: &KnowledgeAdapter| {
            let mut edges = rows(
                adapter,
                "MATCH (n:Npc)-[e:Npc__KNOWS__Lore]->(l:Lore) RETURN l.id, e._hxn_revision",
            );
            edges.sort_by_key(|row| format!("{:?}", row[0]));
            edges
        };
        let update = partial(
            &npc,
            2,
            json!({}),
            json!([["a", "b"], []]),
            Value::Null,
            json!(["KNOWS"]),
        );
        adapter.apply_json(&update).expect("add b");
        // The unchanged edge keeps the revision that created it; only the new one is written.
        assert_eq!(
            known(&adapter),
            vec![
                vec![string("a"), TypedValue::Int64(1)],
                vec![string("b"), TypedValue::Int64(2)]
            ]
        );
        let complete = batch(
            1,
            3,
            vec![node(
                &npc,
                "sage",
                json!({"goal":"guard","name":"Mira"}),
                json!([["b"], ["north"]]),
                bounds("north", 1.0),
            )],
        );
        adapter.apply_json(&complete).expect("drop a");
        assert_eq!(
            known(&adapter),
            vec![vec![string("b"), TypedValue::Int64(2)]]
        );
        let links = rows(&adapter, "MATCH (n:Npc) RETURN n._hxn_links");
        assert_eq!(links[0][0], string(r#"[["b"],["north"]]"#));
    }

    #[test]
    fn spatial_value_and_world_move_together() {
        let (_database, mut adapter, npc) = seeded();
        let moved = partial(
            &npc,
            2,
            json!({}),
            json!([[], ["south"]]),
            bounds("south", 5.0),
            json!(["IN_WORLD"]),
        );
        adapter.apply_json(&moved).expect("move");
        let row = &rows(
            &adapter,
            "MATCH (n:Npc)-[:Npc__IN_WORLD__World]->(w:World) RETURN w.id, n._hxn_world, n._hxn_min_x",
        )[0];
        assert_eq!(
            row,
            &vec![string("south"), string("south"), TypedValue::Double(5.0)]
        );
        let missing = partial(
            &npc,
            3,
            json!({}),
            json!([[], ["north"]]),
            Value::Null,
            json!(["IN_WORLD"]),
        );
        assert!(adapter.apply_json(&missing).is_err());
    }

    #[test]
    fn partial_snapshots_need_a_live_complete_entity() {
        let (lore, _, npc) = schemas();
        let (_database, mut adapter) = adapter();
        adapter
            .apply_json(&batch(
                1,
                1,
                vec![node(
                    &lore,
                    "a",
                    json!({"title":"A"}),
                    json!([]),
                    Value::Null,
                )],
            ))
            .expect("lore");
        let unknown = partial(
            &npc,
            2,
            json!({"goal":"x"}),
            json!([[], []]),
            Value::Null,
            json!(["goal"]),
        );
        assert!(adapter.apply_json(&unknown).is_err());

        let (_database, mut adapter, npc) = seeded();
        let mut tombstone = node(&npc, "sage", json!({}), json!([]), Value::Null);
        tombstone["deleted"] = Value::Bool(true);
        adapter
            .apply_json(&batch(1, 2, vec![tombstone]))
            .expect("delete");
        assert!(
            rows(
                &adapter,
                "MATCH (n:Npc)-[:Npc__KNOWS__Lore]->(l:Lore) RETURN l.id"
            )
            .is_empty()
        );
        let after = partial(
            &npc,
            3,
            json!({"goal":"x"}),
            json!([[], []]),
            Value::Null,
            json!(["goal"]),
        );
        assert!(adapter.apply_json(&after).is_err());
    }

    #[test]
    fn partial_selections_are_validated() {
        let (_database, mut adapter, npc) = seeded();
        let mut version1 = node(
            &npc,
            "sage",
            json!({"goal":"x"}),
            json!([[], []]),
            Value::Null,
        );
        version1["fields"] = json!(["goal"]);
        assert!(adapter.apply_json(&batch(1, 2, vec![version1])).is_err());
        for (facts, links, fields) in [
            (json!({"goal":"x"}), json!([[], []]), json!([])),
            (
                json!({"goal":"x"}),
                json!([[], []]),
                json!(["goal", "goal"]),
            ),
            (json!({"goal":"x"}), json!([[], []]), json!(["unknown"])),
            (
                json!({"goal":"x","name":"y"}),
                json!([[], []]),
                json!(["goal"]),
            ),
            (json!({"goal":"x"}), json!([["b"], []]), json!(["goal"])),
        ] {
            assert!(
                adapter
                    .apply_json(&partial(&npc, 2, facts, links, Value::Null, fields))
                    .is_err()
            );
        }
    }

    #[test]
    fn complete_batches_serialize_as_version_one() {
        let (_, _, npc) = schemas();
        let json = batch(
            1,
            1,
            vec![node(
                &npc,
                "sage",
                json!({"goal":"g","name":"n"}),
                json!([["a"], ["north"]]),
                bounds("north", 1.0),
            )],
        );
        let parsed: Batch = serde_json::from_str(&json).expect("batch");
        assert!(
            !serde_json::to_string(&parsed)
                .expect("serialize")
                .contains("\"fields\"")
        );
    }
}
