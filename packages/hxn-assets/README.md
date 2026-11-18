# hxn-assets

Asset catalogs and asynchronous byte loading over a pluggable `AssetSource`.
Catalogs validate addresses and dependencies; the loader orders dependencies,
verifies optional SHA-256 content IDs and caches bytes within a configurable budget.

```haxe
final catalog = new hxn.assets.AssetCatalog([
    {address: "start", path: "levels/start.json"}
]);
final files = new hxn.file.Storage("com.example.game");
final loader = new hxn.assets.AssetLoader(new hxn.assets.FileSource(files), catalog);
loader.load("start").then(bytes -> loadLevel(bytes));
```

`unload(address)` invalidates a cached payload. `clear()` empties the cache;
`close()` also rejects new loads. Returned bytes are independent copies.
`FileSource` borrows its storage, so close the storage separately.

The installed haxelib registers these hxn CLI commands:

```text
hxn assets catalog --source assets --out catalog.json --content-addressed
hxn assets stage --source assets --out build/assets --content-addressed
```

Omit `--content-addressed` to avoid hashing. Compiler integration stages `assets/`
automatically; `-D hxn_assets_content_addressed` includes SHA-256 IDs in its catalog.
Custom providers implement `AssetSource.read` or `CatalogSource.load`, returning
`hxn.Future`. The package has no graph or hosted-service dependency.

See [design](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md) and
[conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md).
