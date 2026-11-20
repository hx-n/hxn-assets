# KyuGraph projection core

This internal Rust component implements knowledge batch projection (format
versions 1 and 2, the latter carrying partial snapshots)
for the installed hxn-assets KnowledgeGraph API. It belongs to the shared Cargo
workspace. Haxe consumers use the normal hxn-assets haxelib, which contains its
prebuilt scalar and supported JIT variants; they do not compile this crate.

KnowledgeAdapter.apply_json updates graph values and source revisions in one
delta. Node upserts name only the columns a snapshot selects, and relationship
edges are diffed against the stored targets. The facade serializes database operations. Schema changes require
explicit migration. Scalar arrays use JSON text STRING columns for KyuGraph
0.4 DDL. Queries scope namespaces and exclude tombstones. Namespaces do not
replace application authorization.

examples/replay.rs applies the exported Haxe lore/progress/NPC/spatial scenario,
then checks replay and database restart. Repository verification runs
`python3 tests/knowledge/run.py --adapter` from the workspace root. Installed
consumer checks exercise KnowledgeGraph through both CLI flags without Rust.

The native dependency notices ship with
[hxn-assets](../../packages/hxn-assets/third-party/NOTICES.md), including its
native inventory and applicable source archives. They do not belong to hxn-file
or core hxn. See the [knowledge contract](../../docs/knowledge.md).
