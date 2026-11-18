---
name: hxn-assets
description: Use or change hxn-assets catalogs, dependency loading, optional content identity, byte caching, providers and the hxn assets CLI.
---

Use AssetCatalog for descriptors and dependency validation, AssetLoader for
asynchronous byte loading, and FileSource to borrow hxn.file.Storage. Custom
AssetSource and CatalogSource providers return hxn.Future. Loader-returned bytes
are owned copies; unloading must also invalidate stale in-flight cache writes.

The installed haxelib supplies `hxn assets catalog` and `hxn assets stage`, each
with `--source`, `--out` and optional `--content-addressed`. Compiler integration
uses `hxn_assets_dir` and opt-in `hxn_assets_content_addressed` defines. Consumers
use hxn and installed haxelibs, without repository shell helpers.

Read the [asset API](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-assets/README.md),
[design](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md) and
[conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md).
Use this repository's git-bug tracker. Graph projection annotations and the
hosted assets service are separate issue plans; do not describe them as
implemented APIs or add graph/service requirements to basic asset loading.
