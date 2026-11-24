# hxn-file

```text
haxelib install hxn-file 0.2.2
```

Read bundled assets and persist application saves and string preferences through
`hxn.Future`, using the same Haxe API on native and browser runtimes.

```haxe
final files = new hxn.file.Storage("com.example.game");
files.readAsset("levels/start.json").then(bytes -> loadLevel(bytes));
files.writeSave("slots/one.bin", saveBytes).then(_ -> showSaved());
files.setPreference("language", "en");
```

Keep the storage object while using it and call `close()` when finished. Started
operations keep their state until completion. Handle rejected futures; missing
saves reject, while a missing preference returns `{found: false, value: ""}`.

Put bundled files under `assets/`, or select a directory with
`-D hxn_assets_dir=<directory>`. The init macro copies them beside compiler output.
Mobile application hosts must package that directory as bundle/APK assets.
An Android host must initialize `ndk-context` with its VM and application context.

Desktop defaults use an application-specific data directory; iOS uses Application
Support, Android uses its private files directory, and browser persistence uses
an application-named IndexedDB database within the origin. `StorageOptions` can
override `assetDirectory` and the parent `dataRoot` for native hosts.

Browser builds need a served page host: Ash wasm with browser agents, or hxcpp
with Emscripten, threaded or unthreaded. Use `then` on the browser page thread.
There is no standalone WASI filesystem backend.

The package also supplies the URI I/O backend used by hxn-assets RemoteSource:
HTTP(S) reads/chunks and WS(S) messages, with bounded results and explicit cancellation.
Consumers normally use the typed asset source/stream API.

See [design and limits](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md)
and [dependency notices](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/third-party/NOTICES.md).

## Logging

Diagnostics use core `hxn.Log` with target `hxn.file`.
The application owns `Log.level` and `Log.sink`; frame loops drain native
records at `hxn.Loop.sync()`, and idle background work uses `Log.flush()`.
