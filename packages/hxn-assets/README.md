# hxn-assets

```text
haxelib install hxn-assets 0.2.1
```

Declare assets in Haxe metadata and read them as their actual data types.
JSON can be `Dynamic` or a typed structure, text is `String`, binary is `Bytes`,
and PNG images are portable `ImageData` pixels.

```haxe
typedef LevelData = {name:String, lives:Int};

@:build(hxn.assets.Assets.build())
class GameAssets {
    @:asset("levels/start.json")
    @:contentAddressed
    public static var Start:LevelData;

    @:asset("live/level.json")
    @:dynamicAsset
    public static var Live:LevelData;

    @:asset("wss://assets.example/world")
    @:dynamicAsset
    public static var Events:hxn.assets.AssetStream<{entity:String, x:Float, y:Float}>;
}

trace(GameAssets.Start.name); // decoded data embedded at compilation
```

Mark runtime data with `@:dynamicAsset`. `GameAssets.load(loader)` asynchronously
loads and decodes those fields through an `AssetLoader`; read them after it
completes. A declared payload type selects the decoder and validates the value.
An untyped dynamic field receives raw bytes for application decoding.
`@:assetDecode(MyCodec.decode)` supplies a custom `Bytes -> T` decoder.

RemoteSource supports HTTP(S) values and byte-chunk streams, and WS(S) message
streams. `AssetStream<T>.next()` returns a future of `{done, value, text}`;
`listen` consumes messages and `close` cancels the connection. Use a
`RemoteSource` with a borrowed FileSource fallback when a catalog mixes local
and remote keys. The stream's payload type selects per-message decoding.

The macro generates the catalog and optional SHA-256 IDs. Provider-based loading
uses `GameAssets.catalog()` and `GameAssets.addresses.Start`. `FileSource` borrows
an hxn-file Storage; custom sources return `hxn.Future<Bytes>`.

Another build macro can extend the declarations: it changes the fields of
`Context.getBuildFields()`, then returns `hxn.assets.Assets.process(fields)`,
which does what `build()` does with those fields.

The installed haxelib also supplies whole-directory imports:

```text
hxn assets catalog --source assets --out catalog.json --content-addressed
hxn assets stage --source assets --out build/assets --content-addressed
```

See [types, metadata and lifecycle](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md#asset-declarations),
[conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md) and
[codec notices](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-assets/third-party/NOTICES.md).

Knowledge metadata selects typed identities, facts, relationships and world-space
bounds from assets and live state. See the
[lore, progress and NPC example](https://github.com/hx-n/hxn-assets/tree/main/examples/knowledge)
and [knowledge guide](https://github.com/hx-n/hxn-assets/blob/main/docs/knowledge.md).
The included KnowledgeGraph accepts the same versioned snapshots.

## Logging

Diagnostics use core `hxn.Log` with target `hxn.assets`.
The application owns `Log.level` and `Log.sink`; frame loops drain native
records at `hxn.Loop.sync()`, and idle background work uses `Log.flush()`.

## Embedded knowledge graph

`hxn.assets.KnowledgeGraph` is included with prebuilt bindings for desktop,
mobile and browser targets. Use it as the sink for annotated lore, progress,
NPC relationships and spatial state, then query through the Haxe Cypher API.
Save and load portable checkpoints with `hxn.file.Storage`, including browser
IndexedDB. See the [knowledge guide](https://github.com/hx-n/hxn-assets/blob/main/docs/knowledge.md)
and [game example](https://github.com/hx-n/hxn-assets/tree/main/examples/knowledge).

Compile with `hxn assets build --jit app.hxml` or `--no-jit` to choose a prebuilt
engine. The default selects available JIT, otherwise scalar. Desktop and Android
include both; iOS and wasm use scalar/vectorized queries. Haxe consumers need no
Rust tooling or extra graph package.
