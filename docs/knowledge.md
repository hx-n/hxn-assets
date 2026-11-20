# Knowledge metadata

Knowledge metadata describes what application data means. It selects fields
from Haxe classes and typedefs. The same model describes lore, dynamic assets,
quest progress, NPC memories and goals, world state, and relationships.
NPCs are non-player characters. The application defines the vocabulary.
The library supplies typed identities, facts, relationships, and spatial bounds.

A schema describes selected fields and their types. A snapshot is a copied
selection of current values.

```haxe
import hxn.assets.KnowledgeRef;

@:knowledge("Lore")
typedef Lore = {
    @:identity var id:String;
    @:fact var title:String;
}

@:knowledge("World")
typedef World = {
    @:identity var id:String;
    @:fact var name:String;
}

@:knowledge("Npc")
typedef Npc = {
    @:identity var id:String;
    @:fact var goal:String;
    @:fact var memories:Array<String>;
    @:relation("KNOWS") var knowledge:Array<KnowledgeRef<Lore>>;
    @:relation("IN_WORLD") var world:KnowledgeRef<World>;
    @:spatial("world", "metre") var position:{x:Float, y:Float, z:Float};
    var privatePrompt:String;
}
```

`Knowledge.capture(value)` is a macro that reads each selected field once and
returns an owned KnowledgeSnapshot. Unannotated fields are excluded. Retain
the declared class or typedef type when you pass data. Dynamic has no semantic
schema. Capture performs no graph I/O and does not observe later mutations.
Selected getters execute application code. Select values that the application
intends to share.

| Metadata | Meaning |
|---|---|
| `@:knowledge("Npc", 1)` | Semantic type and optional positive schema version, default 1. |
| `@:identity` | Exactly one required String field containing a stable ID. |
| `@:fact` / `@:fact("name")` | Selected property, optionally renamed. |
| `@:relation("KNOWS")` | KnowledgeRef<T> or an array of references to an annotated type. |
| `@:spatial("world", "metre")` | A point or bounding box in the coordinate space named by the required single relation field `world`. Units default to `unit`. |

The spatial schema records the selected relationship and units, so changing
either requires an explicit schema migration.

Facts support String, Int, Float, Bool, nullable values and homogeneous arrays
of non-null scalars. Optional fields become nullable facts. Model structured
knowledge through annotated types and relationships. Dynamic objects, binary
blobs and recursive property serialization are excluded. Class fields must be
declared directly; inherited models require an explicit flattened schema.

KnowledgeRef<T> is represented as a String, including in typed JSON assets;
the macro checks its annotated target type. Identities are nonempty, contain no
NUL and fit in 256 UTF-8 bytes. Schema/property/relation names are ASCII
identifiers beginning with a letter, at most 64 characters long.

An AABB is a box aligned with coordinate axes. Spatial values accept x/y[/z] points or minX/minY/maxX/maxY[/minZ/maxZ] bounds.
Missing Z is zero. Numbers must be finite and bounds ordered. Applications
supply resolved world coordinates and bounds; parent transforms are not
evaluated. Queries compare matching namespace, world and units.

## Assets and live state

Use the annotated typedef as an asset's expected payload type.
`Knowledge.capture(GameAssets.Ruin)` retains its generated address and optional
source-byte content ID, including after dynamic loading. Capture a dynamic
asset after its load future completes. Detached local values have no implicit
asset provenance. Transport URIs, query tokens and headers are excluded.

Semantic IDs remain stable as state changes. Content IDs identify source bytes,
not mutated decoded objects or knowledge snapshots. Player/campaign/session
scope belongs in the knowledge namespace. Save-backed progress is eligible
when explicitly selected; loading a save does not publish it automatically.
Authored lore, observations and generated claims can carry application-defined
provenance/status facts and distinct relationships.

## Publication and queries

A sink accepts a batch of knowledge changes. A namespace scopes data to an
application or campaign. A source identifies the writer. A revision numbers an
update from that source. A batch groups snapshots under one revision.
A tombstone marks an entity as deleted.

```haxe
final sink = new hxn.assets.knowledge.MemoryKnowledgeSink();
final knowledge = new hxn.assets.Knowledge("campaign/one", "game", sink);
knowledge.publish(1, [
    hxn.assets.Knowledge.capture(GameAssets.Ruin),
    hxn.assets.Knowledge.capture(world),
    hxn.assets.Knowledge.capture(npc)
]).then(_ -> trace("Knowledge accepted"));
```

The Haxe event thread delivers asynchronous results. Publish on that thread.
Each changed entity supplies a complete selected snapshot. The snapshot
replaces its facts and outgoing relationships. Repeated
identities in a batch coalesce to the last value. Publish every referenced
semantic type in the initial batch or an earlier batch. A target ID can resolve
later. Reference queries omit missing or deleted targets. References stay within
the publication namespace. Sources own entities independently; replacing another
source's entity is rejected. After a schema change, migrate the stored data.
An increase to the version number alone does not migrate a sink.

`Knowledge.remove(value)` reads only identity and emits a tombstone. Incoming
references can remain. Queries must exclude deleted targets. A later accepted
revision from the owner can restore an entity. An older revision cannot undo deletion.
MemoryKnowledgeSink offers detached get/all/related/within results. Its inclusive
AABB query scans nodes and does not imply a spatial index.

One publisher permits one request in flight. Revisions are increasing positive
Int values per namespace/source. After failure, retry() sends the identical owned
batch before another revision can publish. Publication starts no timer, network
connection or thread and does not persist its retry state. Applications/sinks own
durable outboxes, authentication, reconnect scheduling and authority policy.
These APIs do not implement CRDT merging or a durable local edit journal.

Snapshots fit in 256 KiB. Batches fit in 1 MiB and accept at most 256 input
snapshots. Schemas select at most 64 facts and relations in total. Scalar strings
fit in 64 KiB. Scalar arrays and relation lists have at most 1024 members. Serialization budgets
are checked while traversing selected values. Application-owned inputs are outside
these captured-data budgets. Size the application heap for live values plus
JSON encoding. Emscripten applications can enable HXCPP_LINK_MEMORY_GROWTH
through their Haxe configuration.

## Embedded graph

KnowledgeSink.apply returns hxn.Future<Unit>. KnowledgeBatch.toJson produces
version-1 UTF-8 JSON. The data() method gives providers detached values. Sinks preserve
replacement, ownership, schema validation, replay and tombstones.

The normal hxn-assets haxelib includes prebuilt KyuGraph binaries and the
`hxn.assets.KnowledgeGraph` facade. No Rust compiler or separate backend package
is required. Opening a graph returns a future. Pass that graph to Knowledge as
its sink, then execute Cypher with named parameters:

```haxe
KnowledgeGraph.open().flatMap(graph -> {
    final knowledge = new Knowledge("campaign/one", "game", graph);
    return knowledge.publish(1, [Knowledge.capture(npc)])
        .flatMap(_ -> graph.query(
            "MATCH (n:Npc) WHERE n._hxn_namespace = $scope AND n._hxn_deleted = false RETURN n.id",
            {scope: "campaign/one"}))
        .flatMap(result -> {
            trace(result.rows);
            return graph.close();
        });
});
```

Publish related schemas/entities first, as described above. Query results own
their column names, type names and decoded rows. Values include scalars, nested
lists/objects and Bytes; 64-bit integers outside the Haxe Int range use haxe.Int64.
Integers wider than signed 64 bits use decimal strings. Parameters accept Haxe
scalars, haxe.Int64, Bytes, lists and anonymous objects. Bind values as parameters.

`KnowledgeGraph.open()` creates an in-memory graph on every platform.
`open(directory)` additionally supports native filesystem persistence. Browser
code uses memory graphs with `save(storage, path)` and `load(storage, path)` for
application-scoped IndexedDB persistence. `snapshot()` and `restore(bytes)` use
the same versioned checkpoint format without filesystem access. Saves are
explicit, not automatic after publication. Checkpoints are compatible between
scalar and JIT builds of the same format. Await outstanding work before close;
close rejects new work and releases the native handle after shutdown.

Use `hxn assets build --jit app.hxml` or `hxn assets build --no-jit app.hxml` to
choose the installed engine. Without a flag, the compiler selects JIT where
available and scalar otherwise. Direct Haxe builds use `-D hxn_assets_jit=on`,
`off` or `auto`. Desktop and Android packages include both builds. iOS and wasm
use scalar/vectorized evaluation; an explicit unsupported JIT request fails
with a target-specific message. These flags control KyuGraph, independently of
Ash's own execution mode. CPPIA scripts must match their native host's selection.
The graph's `jit` property reports the actual selected build.

Emscripten graph programs use an 8 MiB native stack for parsing and evaluation.
KnowledgeGraph adds the link setting when used; byte-only asset programs keep
their existing stack policy. Override with the Haxe define
`hxn_assets_stack_size=<bytes>` when configuring the application. This is
independent of heap growth and of the JIT build choice.

Each graph allows eight pending operations. Inputs are copied before returning
futures. Native CPU work is serialized on worker tasks; a non-threaded wasm build
runs CPU work synchronously without starting threads. Keep expensive queries out
of latency-sensitive paths. Query text is limited to 64 KiB, parameters to
256 KiB/64 bindings (names and object field names up to 256 characters), results to 1024 rows/64 columns and 1 MiB of encoded values,
and checkpoints to 64 MiB. Result limits do not bound engine intermediate work.

The internal projection component under adapters/kyugraph accepts batch JSON
through KnowledgeAdapter::apply_json. It generates typed tables and uses DeltaBatchBuilder
for graph updates and the stored source revision in one delta. A delta is a
group of changes applied together. Replaying an accepted batch leaves the graph
unchanged. The adapter ignores older revisions. It rejects equal revisions that
contain different data. Ownership and tombstones survive restart. Schema DDL is registered
separately. A later failure can leave unused tables. The adapter does not
acknowledge a failed data revision.

Relationship tables use Source__RELATION__Target, e.g. Npc__KNOWS__Lore. Nodes
carry _hxn_namespace, _hxn_deleted, source/revision, optional asset provenance and
spatial _hxn_* columns. Scope queries and exclude tombstones on every semantic
node. Query values use parameter bindings. The adapter checks and quotes
identifiers.
Scalar arrays use JSON text in STRING columns because KyuGraph 0.4 Cypher DDL
cannot declare list columns. Use related entities for queryable collection members.

The facade serializes operations per database. Namespaces organize data; they do
not authorize access. Connected applications can provide a KnowledgeSink
transport and an authorized endpoint. The embedded API does not implement
remote hosting, synchronization or CRDT merging.

See the [runnable model/scenario](../examples/knowledge/README.md) and
[KyuGraph query](../adapters/kyugraph/examples/replay.rs) combining lore, progress,
NPC behavior, relationships and bounds, followed by updates, deletion and replay.
