# Design

This monorepo separates platform I/O (`packages/hxn-file`) from asset metadata
and byte loading (`packages/hxn-assets`). hxn-file pins hxn 0.3.9 for generated
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

## Asset declarations

Use `@:build(hxn.assets.Assets.build())` on a class of annotated static fields
without initializers. An asset field contains its payload. Embedded JSON becomes
a Haxe literal checked against its declared anonymous structure or typedef;
`Dynamic` accepts the decoded JSON value. String fields contain text, Bytes
fields contain raw payload bytes, and ImageData contains decoded RGBA8 pixels.
Fields are read-only bindings; contained objects and byte buffers remain mutable
application values. Generated addresses live separately under `Class.addresses`.
The generated `catalog()` returns a fresh descriptor snapshot.

| Metadata | Meaning |
|---|---|
| `@:asset("path")` | Asset source key; the field name is its logical address. |
| `@:asset("address", "path")` | Explicit logical address and source key. |
| `@:contentAddressed` or `@:contentAddressed("sha256")` | Compute a content ID from source bytes; applicable to a field or declaration class. |
| `@:dynamicAsset` | Load the field at runtime through the generated asynchronous `load(loader)` method. |
| `@:assetFormat("json")` | Explicitly select json, text, binary, png, xml or haxe decoding. |
| `@:assetDecode(MyCodec.decode)` | Application `Bytes -> T` decoder for a dynamic field. |
| `@:assetDependsOn(OtherField, ...)` | Dependencies on annotated fields in the same class. |
| `@:assetGroup("name")` | Group lookup metadata. |
| `@:assetLabels("label", ...)` | Label lookup metadata. |
| `@:assetMediaType("type/subtype")` | Media type metadata. |

Embedded source files resolve from `hxn_assets_dir` or `assets/`. Compilation
rejects missing source files, nonportable/escaping paths, duplicate addresses,
malformed annotations, unknown dependencies and cycles. Data that cannot be
inferred/decoded at compilation requires a dynamic declaration or an explicit
supported payload type. Binary bytes and decoded pixels are Haxe resources;
JSON and text are literal values. XML is validated at compilation and its embedded
text is parsed during field initialization. Plain Haxe-serialized values can
be decoded and emitted as literals using `@:assetFormat("haxe")`; class instances
and other values the compiler cannot express require an application runtime decoder.
PNG parsing uses HaxeFoundation format with checked chunk lengths, bounded
decompression and validated palette indices. The decoder supports non-interlaced
8-bit RGB/grayscale and 1/2/4/8-bit indexed PNG. Other bit depths, interlaced PNG
and other image encodings need an application decoder. ImageData is unpremultiplied, tightly packed RGBA8 with rows top first,
limited to 64 MiB of decoded pixels. Creating a GPU texture remains an application
operation requiring a graphics device.

### Dynamic fields

`@:dynamicAsset` permits source keys whose bytes are unavailable at compilation.
A field declared `Dynamic` receives raw Bytes for application decoding unless an
explicit format/decoder is selected. A typed anonymous structure, typedef,
array or scalar selects JSON decoding; String, Bytes, Xml and ImageData select
their respective decoders. Expected JSON types generate runtime validation of
required/optional fields, nested structures, arrays, nullability and primitive
values. Class-valued or recursive schemas require `@:assetDecode`, whose return
type is checked by Haxe. The format annotation can override inference.

The generated `load(loader):Future<Unit>` loads all dynamic fields in declaration
order, decodes into temporary values and publishes them together after success.
Access before completion throws. Failure publishes no partial group. Repeated
loads and `unload()` supersede older pending results; started source operations
still finish. `unload()` releases dynamic field bindings. Loader byte-cache
invalidation is separate: use AssetLoader.unload/clear when a source revision
changes. Embedded fields remain available independently of this lifecycle.

### Catalog generation and staging

Content addressing is opt-in and hashes exact source bytes, independently of
the decoded Haxe value. A dynamic field requesting a content ID must supply
known bytes at compilation. Generated typed metadata carries descriptors into
staging. Source files are compiler dependencies, including embedded binary
resources, so asset edits invalidate cached declaration modules.

Compiler staging copies selected source files and writes the combined catalog
to `.hxn-assets.json`. Missing dynamic sources and remote URIs remain descriptors for the runtime
provider. All included declaration classes share the staged address namespace;
addresses must be unique across those classes. Hashes are verified against copied
bytes before writing the manifest. Each class's catalog contains its own entries.
Direct AssetCatalog construction and JSON imports support provider/import
boundaries and low-level validation tests. Semantic knowledge capture is separate
from byte loading; providers acquire no graph or service dependency.

## Knowledge metadata

[Knowledge metadata](knowledge.md) describes typed identities, selected facts,
relationships, spatial bounds and versioned sink publication. Its optional
native KyuGraph adapter is separate from the portable Haxe package.

## Remote values and streams

Dynamic `@:asset` declarations accept HTTP, HTTPS, WS and WSS URIs. URI metadata
never causes network access during compilation. Credentials in URI user-info
and URI fragments are rejected. HTTP(S) fields can resolve typed values;
WS(S) fields must be `AssetStream<T>`. HTTP stream fields are Bytes chunks
unless an application supplies a framing decoder. Network chunks do not imply
JSON/message boundaries. Local source keys remain portable relative paths.

`RemoteSource` implements AssetSource and StreamingAssetSource. Its optional
borrowed local fallback can be a FileSource. AssetLoader.openStream loads byte
dependencies, then opens the stream without caching its unbounded sequence.
There is no whole-stream content digest. Runtime catalog snapshots can still
supply content IDs for bounded downloads verified by the loader before decoding.

`AssetStream<T>` wraps a pull driver. Each `next()` returns a future containing
`done`, nullable `value` and the WebSocket `text` flag. A null value or an empty
message differs from end. Only one reader is pending per connection, including
mapped views; closing any view closes their shared driver. An explicit close
rejects a pending `next()` and finishes active `listen` consumers normally. `listen` pulls after
each synchronous handler returns, and its returned function cancels consumption.
Use explicit next calls when application work must finish before the next pull.
The generated asset-group load opens stream objects without waiting for a first
message; stream errors arrive on reads. Group failure/unload/reload closes owned
streams, including those opened before a later field fails. No reconnect is hidden
inside the transport.

The native URI backend is provided by hxn-file alongside platform I/O. It uses
ureq for HTTP(S) and tungstenite for WS(S), with certificate verification through
rustls. Browser operations reuse the page-owned mailbox and native Future queues;
they do not retain transient guest pointers. The page fetches HTTP bodies and owns
WebSockets. Streaming sockets keep its event loop live, even without a pending
read. Native HTTP reads pull chunks; WebSocket reads preserve complete message
boundaries, including fragmented protocol frames and empty messages.

RemoteOptions defaults are 30-second connection/read timeouts, a 16 MiB snapshot
or message limit and 64 KiB HTTP chunks. Configuration is bounded below 64 MiB
per result, at most 1 MiB per HTTP chunk, 32 headers and 16 subprotocols.
Native connection count is bounded to 64; one operation is pending per connection.
The browser shares the file bridge's 16-job and 128 MiB owned-buffer budgets and
caps queued WebSocket messages at 16. An oversized message or a full browser queue
fails/closes the stream; it never grows an unbounded message cache. Cancellation
settles pending reads and closes/aborts transport work. Application-owned returned
values are outside the stream queue's budget.

Applications supply headers and subprotocols at runtime. Browser fetch uses CORS
and omits credentials; browser WebSockets use browser-controlled cookies and can
use subprotocols or signed URIs. They cannot set arbitrary request headers.
Native caCertificates explicitly replaces the default trust roots with supplied
PEM roots for private/self-hosted services; browser trust remains browser policy.
The SDK has no production certificate-verification bypass. Mobile application
hosts supply their platform network permissions and decide suspend/reconnect
policy. Embedded assets require no live network or transport initialization.

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
Directory import without declarations uses a source walker that rejects escaping
symlinks, cycles and case-insensitive name collisions. Staging copies selected
entries and writes `.hxn-assets.json`; it does
not remove unrelated or old files in the destination. CLI staging requires an
output directory outside the source tree.

The hxn-assets haxelib declares the `assets` namespace in `hxn.cli` metadata.
Its Haxe tool accepts the version-1 command request and implements `catalog` and
`stage`. Consumers invoke it through hxn using an installed haxelib. Test hosts
and fixtures are separate from this public tool.
