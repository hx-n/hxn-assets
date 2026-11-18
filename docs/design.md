# Design

This monorepo separates platform I/O (`packages/hxn-file`) from asset metadata
and byte loading (`packages/hxn-assets`). hxn-file pins hxn 0.3.8 for generated
bindings; hxn-assets is Haxe and uses those bindings through `FileSource`.

## File ownership and persistence

`Storage` wraps a shared `StorageBackend`. Operations copy input strings/bytes
before returning futures. Closing the facade prevents further calls; started
operations retain shared state. Native blocking I/O runs through
`hxn_future::spawn_blocking` with at most 16 operations per backend.

Assets are read-only. Saves and preferences have separate directories beneath
an application namespace. Paths are relative, contain no traversal or platform
reserved components, and are checked before use. Native directories are cap-std
capabilities; resolving a symlink cannot grant access outside the opened root.
Save replacement writes and syncs a temporary sibling, renames it, then syncs
the directory on Unix. Preferences use independent files per hex-encoded key.

Native default data roots are Application Support on Apple platforms,
LOCALAPPDATA on Windows, and XDG_DATA_HOME or HOME/.local/share on Linux.
Apple bundle assets use NSBundle; Android assets use AAssetManager. Android
requires its application host to initialize ndk-context. Explicit `dataRoot`
is a parent directory: the application ID is appended to it.

Whole-file reads and writes are limited to 64 MiB. Preferences are strings up
to 64 KiB with keys up to 96 UTF-8 bytes. A missing preference differs from
an empty stored string. Missing file reads reject their futures. Application IDs
and portable relative paths are validated consistently across backends.

## Browser transport

Bundled paths are encoded per URL segment and fetched relative to the assets
base URL. Saves and preferences use separate keys in IndexedDB database
`hxn-file:<application>` under the page origin. Results settle only after the
transaction completes. Browser quota, private browsing and eviction remain
browser policy; persistence failures reject futures.

A permanent mailbox coordinates Rust and the page service. Guest writes are
copied synchronously before acknowledgment. Async fetch/IndexedDB results remain
page-owned until Rust requests a sized synchronous copy. A pending entry retains
the store until completion. The browser service bounds pending work to 16 and
buffered data to 128 MiB; fetches time out after 30 seconds.

Ash uses its host-agent/watch protocol. Threaded Emscripten uses a page agent and
a private completion waiter; unthreaded Emscripten polls without blocking the
page thread. The Haxe application receives results through hxn's event loop.
These backends require a browser page; standalone WASI/Node is not a file backend.

## Catalogs and loading

`AssetCatalog` owns defensive copies of descriptors. Addresses are unique;
unknown dependencies and cycles are rejected. It supports address, group and
label lookups and dependency order. JSON catalogs use schema version 1.
An optional content ID is `sha256:` followed by a lowercase hexadecimal digest.

`AssetLoader` is used on the Haxe event thread. It loads dependencies before the
requested payload, deduplicates pending reads and cache entries by content ID
(or address when absent), verifies content IDs before caching, and returns
copies of cached bytes. Defaults are 64 MiB of cached bytes and 16 pending
source reads. Cache eviction uses least-recently-used entries. Per-key generations
and a global clear epoch keep stale completions from repopulating invalidated
entries. A caller already holding a future still receives that operation's result.

`AssetSource` provides byte reads; `CatalogSource` provides catalogs.
`FileSource` borrows a Storage; `StaticCatalog` returns an existing catalog.
Providers do not imply graph projection, authentication or a service dependency.

## Compiler and CLI integration

The hxn-file init macro copies selected assets and the browser module beside
compiler output. hxn-assets installs its catalog/staging macro and marks staging
as managed, so the lower-level macro does not also copy assets.
The source walker rejects escaping symlinks, cycles and case-insensitive name
collisions. Staging copies source entries and writes `.hxn-assets.json`; it does
not remove unrelated or old files in the destination. CLI staging requires an
output directory outside the source tree.

The hxn-assets haxelib declares the `assets` namespace in `hxn.cli` metadata.
Its Haxe tool accepts the version-1 command request and implements `catalog` and
`stage`. Consumers invoke it through hxn using an installed haxelib. Test hosts
and fixtures are separate from this public tool.
