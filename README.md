# hxn-assets

Two Haxe libraries share this workspace:

| Library | API |
|---|---|
| **hxn-file** | Asynchronous bundled files, application saves and string preferences through `hxn.file.Storage`. |
| **hxn-assets** | Validated catalogs, dependency loading, optional SHA-256 identity and a bounded byte cache. |

File operations return `hxn.Future`. The native backend uses scoped directories;
the browser backend uses fetch for bundled assets and IndexedDB for persistence.
Asset providers implement `AssetSource`, so loading is independent of storage.

See the [file API](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/README.md),
[asset API](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-assets/README.md),
[design](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md) and
[conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md).
Dependency notices belong to the [hxn-file package](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/third-party/NOTICES.md).
