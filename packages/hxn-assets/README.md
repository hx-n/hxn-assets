# hxn-assets

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

The installed haxelib also supplies whole-directory imports:

```text
hxn assets catalog --source assets --out catalog.json --content-addressed
hxn assets stage --source assets --out build/assets --content-addressed
```

See [types, metadata and lifecycle](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md#asset-declarations),
[conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md) and
[codec notices](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-assets/third-party/NOTICES.md).

## Logging

Diagnostics use core `hxn.Log` with target `hxn.assets`.
The application owns `Log.level` and `Log.sink`; frame loops drain native
records at `hxn.Loop.sync()`, and idle background work uses `Log.flush()`.
