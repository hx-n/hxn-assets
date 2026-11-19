# hxn-assets

[![Checks](https://github.com/hx-n/hxn-assets/actions/workflows/checks.yml/badge.svg)](https://github.com/hx-n/hxn-assets/actions/workflows/checks.yml)
[![Native](https://github.com/hx-n/hxn-assets/actions/workflows/native.yml/badge.svg)](https://github.com/hx-n/hxn-assets/actions/workflows/native.yml)
[![Browser](https://github.com/hx-n/hxn-assets/actions/workflows/browser.yml/badge.svg)](https://github.com/hx-n/hxn-assets/actions/workflows/browser.yml)

Two Haxe packages share this workspace. **hxn-file** provides asynchronous file
access and application persistence. **hxn-assets** builds on it with typed,
annotated assets, dependency loading and optional content addressing. Both work
on native and browser runtimes through hxn; applications can use hxn-file alone.

```text
haxelib install hxn-assets 0.1.0
```

This installs hxn-file too. Use `haxelib install hxn-file 0.1.0` for file I/O alone.

## hxn-file: files, saves and preferences

Read bundled bytes, write application-scoped saves and store string preferences.
Operations return `hxn.Future`; browser persistence uses IndexedDB.

```haxe
final files = new hxn.file.Storage("com.example.game");
files.readAsset("levels/start.json").then(bytes -> trace(bytes.toString()));
files.writeSave("slots/one.bin", haxe.io.Bytes.ofString("checkpoint"))
    .then(_ -> trace("Saved"));
files.setPreference("language", "en");
```

Bundled files live in `assets/` by default. Keep `files` while using it and call
`close()` when finished; failed operations reject their futures.
See the [hxn-file API](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/README.md)
for roots, limits and mobile packaging.

## hxn-assets: annotated, typed payloads

Declare assets with metadata rather than writing catalog entries or hashes.
Known data is decoded and embedded at compile time: JSON becomes typed Haxe
values, text becomes `String`, binary becomes `Bytes`, and PNG becomes `ImageData`.

```haxe
typedef LevelData = {name:String, lives:Int};

@:build(hxn.assets.Assets.build())
class GameAssets {
    @:asset("levels/start.json")
    @:contentAddressed
    public static var Start:LevelData;
}
```

With `assets/levels/start.json` containing `{"name":"start","lives":3}`,
`GameAssets.Start.name` is immediately available as `"start"`.
`GameAssets.catalog()` and `GameAssets.addresses.Start` provide the generated
catalog and logical address for provider-based loading.

Mark runtime-only data with `@:dynamicAsset`; its declared type selects decoding
when `GameAssets.load(loader)` completes. `RemoteSource` supports HTTP(S) values
and byte streams, and typed WS(S) message streams. `AssetLoader` loads
dependencies, verifies content IDs and caches bounded byte payloads.
See the [hxn-assets API](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-assets/README.md)
for dynamic fields, remote streams and the `hxn assets` CLI commands.

Knowledge metadata selects typed identities, facts, relationships and world-space
bounds from assets and live state. See the
[lore, progress and NPC example](https://github.com/hx-n/hxn-assets/tree/main/examples/knowledge)
and [knowledge guide](https://github.com/hx-n/hxn-assets/blob/main/docs/knowledge.md).
An optional native KyuGraph adapter consumes the same versioned snapshots.

The [design](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md) and
[conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md)
cover ownership, platform behavior and verification. Each package retains its
own license and third-party notices: [hxn-file](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/third-party/NOTICES.md)
and [hxn-assets](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-assets/third-party/NOTICES.md).
