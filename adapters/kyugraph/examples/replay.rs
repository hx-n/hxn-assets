use std::collections::HashMap;
use std::error::Error;
use std::path::Path;

use hxn_assets_kyugraph::{ApplyOutcome, KnowledgeAdapter};
use kyu_graph::{Database, TypedValue};
use serde_json::Value;

fn candidates(adapter: &KnowledgeAdapter) -> Result<Vec<String>, Box<dyn Error>> {
    let query = r#"
        MATCH (npc:Npc)-[:Npc__KNOWS__Lore]->(lore:Lore)<-[:QuestProgress__ABOUT__Lore]-(progress:QuestProgress)
        WHERE npc._hxn_namespace = $namespace AND progress.player = $player
          AND npc._hxn_deleted = false AND lore._hxn_deleted = false AND progress._hxn_deleted = false
          AND progress.state = $state AND npc._hxn_world = $world AND npc._hxn_units = $units
          AND npc._hxn_min_x <= $max_x AND npc._hxn_max_x >= $min_x
          AND npc._hxn_min_y <= $max_y AND npc._hxn_max_y >= $min_y
          AND npc._hxn_min_z <= $max_z AND npc._hxn_max_z >= $min_z
        RETURN npc.id
    "#;
    let params: HashMap<String, TypedValue> = [
        ("namespace", Value::from("campaign/one")),
        ("player", Value::from("player-1")),
        ("state", Value::from("active")),
        ("world", Value::from("north")),
        ("units", Value::from("metre")),
        ("min_x", Value::from(0.0)),
        ("max_x", Value::from(10.0)),
        ("min_y", Value::from(0.0)),
        ("max_y", Value::from(10.0)),
        ("min_z", Value::from(-1.0)),
        ("max_z", Value::from(1.0)),
    ]
    .into_iter()
    .map(|(name, value)| (name.into(), TypedValue::from(value)))
    .collect();
    let result = adapter.connection().query_with_params(query, params)?;
    result
        .iter_rows()
        .map(|row| match &row[0] {
            TypedValue::String(id) => Ok(id.to_string()),
            _ => Err("invalid NPC query result".into()),
        })
        .collect()
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    let batches: Vec<Value> = serde_json::from_str(&std::fs::read_to_string(&args[1])?)?;
    let path = Path::new(&args[2]);
    let database = Database::open(path)?;
    {
        let mut adapter = KnowledgeAdapter::new(database.connect())?;
        for (index, batch) in batches.iter().enumerate() {
            let json = serde_json::to_string(batch)?;
            assert_eq!(adapter.apply_json(&json)?, ApplyOutcome::Applied);
            let expected = if index == 0 || index == 2 || index == 4 {
                vec!["sage".to_owned()]
            } else {
                vec![]
            };
            assert_eq!(candidates(&adapter)?, expected);
            assert_eq!(adapter.apply_json(&json)?, ApplyOutcome::Replayed);
            println!("revision {}: {:?}", index + 1, expected);
        }
        assert_eq!(
            adapter.apply_json(&serde_json::to_string(&batches[0])?)?,
            ApplyOutcome::Stale
        );
        let mut conflict = batches[0].clone();
        conflict["revision"] = Value::from(6);
        assert!(adapter.apply_json(&conflict.to_string()).is_err());
        assert!(
            adapter
                .connection()
                .query("MATCH (n:Npc) RETURN n.privatePrompt")
                .is_err()
        );
        assert!(candidates(&adapter)?.is_empty());
    }
    drop(database);
    let database = Database::open(path)?;
    let mut adapter = KnowledgeAdapter::new(database.connect())?;
    assert_eq!(
        adapter.apply_json(&batches[0].to_string())?,
        ApplyOutcome::Stale
    );
    assert_eq!(
        adapter.apply_json(&batches[5].to_string())?,
        ApplyOutcome::Replayed
    );
    assert!(candidates(&adapter)?.is_empty());
    // A namespace can reuse semantic IDs without changing another campaign.
    let mut other = batches[0].clone();
    other["namespace"] = Value::from("campaign/two");
    assert_eq!(
        adapter.apply_json(&other.to_string())?,
        ApplyOutcome::Applied
    );
    assert!(candidates(&adapter)?.is_empty());
    let mut malformed = other.clone();
    malformed["revision"] = Value::from(2);
    malformed["nodes"][0]["schema"]["name"] = Value::from("Injected` MATCH (n) DELETE n");
    assert!(adapter.apply_json(&malformed.to_string()).is_err());
    println!(
        "PASS: KyuGraph semantic/spatial queries, replacements, tombstones, replay, namespaces and restart"
    );
    Ok(())
}
