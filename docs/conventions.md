# Conventions

[Design](design.md) describes the implementation. Each repository owns its
issues: run `git bug bug` in this repository before changing an area. Keep
plans, alternatives, measurements and unfinished work in those issues.

## Code and APIs

- Keep platform operations asynchronous through hxn.Future. Copy guest inputs
  before acknowledgment and retain store state for pending work.
- Keep the Rust core independent of HashLink/Ash/hxcpp adapters. Do not select
  runtimes with Cargo features. Generate bindings and the API manifest with hxn.
- Resolve portable relative paths within scoped roots. Keep bundled files
  read-only and saves/preferences separated by application. Complete browser
  writes only after IndexedDB commits.
- Bound whole-file size, pending operations and browser-owned buffers.
- Teach metadata-authored assets with `@:build(hxn.assets.Assets.build())` and
  `@:asset` declarations. Fields contain decoded payload values of the declared
  type; generate addresses separately under `addresses`. Embed known data at
  compilation, and mark runtime-only data with `@:dynamicAsset`. Expected types
  select/validate runtime decoding; untyped dynamic data is application-decoded.
  Reserve hand-built catalogs for provider/import boundaries and low-level tests.
- Canonical filesystem containment uses normalized host separators and directory
  boundaries. Logical asset keys retain their portable forward-slash syntax.
- Knowledge metadata selects typed identities, facts, relations and spatial data.
  Generate reads through Knowledge.capture (complete) or Knowledge.captureFields
  (partial) and exclude unannotated state. Sinks replace a complete snapshot's
  facts and outgoing links, update only a partial snapshot's selected ones, and
  preserve source revisions, tombstones and replay. Keep complete-only batches
  byte-identical to format version 1.
  Follow the [knowledge contract](knowledge.md); KnowledgeGraph is included in the installed hxn-assets package on desktop,
  mobile and browser targets. Projection remains opt-in through annotations and
  publication; it is not a separate optional dependency. Rebuild typed containers after JSON decoding
  before native array operations; dynamic JSON arrays are not typed string arrays.
- Keep asset identity separate from logical addresses. Verify optional digests
  before caching. Keep providers independent of service or graph implementations.
- Keep remote values explicitly dynamic. Preserve WS message boundaries and HTTP
  chunk semantics, bound queues/results, close owned streams on unload/failure,
  and never fetch remote metadata URIs during compilation. Authentication belongs
  to the application; native and browser TLS verification stays enabled.
- Public workflows use installed hxn CLI plugins and compiler init macros.
  Repository-only test runners, app hosts and fixtures live under tests/.
- Update these guides and the package skill when APIs or workflows change.
  Skill documentation links are absolute HTTPS URLs.

## Verification

Run `cargo fmt --all`, `cargo clippy --workspace --all-targets` and
`cargo test --workspace`. Format hand-written Haxe with Haxe formatter.
Run runtime programs under timeouts and repeat concurrent tests.
`python3 tests/knowledge/run.py --ash <ash>` checks schema diagnostics, full DCE
and compiler-server reuse. Add `--adapter` for native projection/replay checks. The adapter and internal JIT
artifact crate are members of this workspace. Run scalar and JIT builds separately
to avoid Cargo feature unification concealing a scalar regression. Installed
consumer checks exercise both CLI flags without Rust, and portable checkpoint
interchange. Native graph notices are owned by hxn-assets; preserve LLVM exception
terms and keep graph dependencies out of hxn-file's inventory.

The file fixture is tests/check/Main.hx, selected by hxn-file's Cargo metadata.
From packages/hxn-file, use `hxn run hl`, `hxn run hl --vm ash`, Ash's JIT and
interpreter options, `hxn run cpp` and `hxn run cppia`. Browser checks use
`hxn run hl --wasm --threads --browser --vm <ash>` and
`hxn run cpp --wasm --browser`, with and without `--threads`.
Use an Ash version supporting wasm native libraries and page agents.

Emscripten graph programs use an 8 MiB native stack for parsing and evaluation.
KnowledgeGraph adds the link setting when used; byte-only asset programs keep
their existing stack policy. Override with the Haxe define
`hxn_assets_stack_size=<bytes>` when configuring the application. This is
independent of heap growth and of the JIT build choice.

Run `python3 tests/assets/run.py --hxn <hxn>` from the workspace root for the
catalog/cache suite, typed embedded/dynamic values, annotation compile errors,
exact staged/runtime catalogs,
inlining/dead-code elimination, compiler-server reuse and asset-edit invalidation.
The runner uses an Ash executable (override with `--ash`) and isolated temporary
output beneath target/. Emscripten fixtures enable HXCPP_LINK_MEMORY_GROWTH for the bounded-payload
stress cases; application heap policy remains configurable.
`tests/assets/runtimes.py` runs the real FileSource and
save fixture with generated catalogs: modes are `hl`, `ash`, `ash-jit`, `ash-interp`,
`cpp`, `cppia`, `wasm`, `emcc` and `emcc-threads`. It uses hxn to build adapters,
then compiles the consumer fixture. Set `--hxn`, `--cli`, `--ash` or `--chrome`
for local tool locations; Emscripten modes need its SDK environment.
`tests/assets/remote.py` runs real HTTP(S)/WS/WSS fixtures with a temporary CA and
server certificate. Native code trusts that CA explicitly; browser tests use a
test-only Chrome flag for the temporary certificate. Include TLS rejection,
fragmented/empty messages, backpressure, errors and pending-read cancellation.
Do not copy that test browser flag into application tooling.
Exercise installed haxelib discovery and direct Haxe compilation as well as hxn.
On macOS, mobile verification uses `python3 tests/mobile/run.py ios-sim|android hl|cpp
--device <simulator-UDID-or-adb-serial>` from the workspace root. The selected
simulator/emulator must already be booted. `--hxn`, `--cli` and `--ash` select
matching local tools. Ash uses its native AOT target. The hxcpp iOS simulator
host uses x86_64 and requires a simulator runtime supporting Intel apps (iOS 17
with Rosetta on Apple Silicon). Install the target standard libraries for the
repository-pinned Rust toolchain. Android uses an arm64 device/emulator, SDK 35,
build-tools 36.1.0, NDK 27.0.12077973 and JDK 17 or newer; `ANDROID_HOME`,
`ANDROID_NDK_ROOT` and `JAVA_HOME` override local SDK locations.

These test-only hosts install a signed simulator app or APK containing staged
assets. Three fresh process launches check default NSBundle/AAssetManager reads,
typed JSON/PNG decoding and content IDs, save/Unicode-preference persistence,
a shared Rust/Haxe log sink, and the real remote fixture. Each build has a
unique success nonce. Android initializes ndk-context in the test adapter’s
Cargo graph, forwards only the fixture ports, and finishes its Activity after
the Haxe event loop drains. Apps and owned port mappings are removed afterward;
build output and captured logs remain under target/mobile. Timeouts bound all
runtime invocations. Final app hosts link platform libraries after hxcpp static
archive construction; the fixture defers those libraries in its private archive
link XML. The Ash Android host supplies the API suffix in its final clang target.
This wiring belongs to tests/, not published hxn CLI tooling. A simulator/emulator
pass does not verify physical devices, suspend/resume or network transitions.
Report runtimes not run.
Windows is not verified until its CI has passed.

The Checks workflow runs Rust, formatting, dependency-notice and annotation
checks on Linux. Native runs the file, asset and remote fixtures under stock
HashLink on Linux/Windows, all three Ash modes, hxcpp and CPPIA on Linux,
macOS and Windows. Browser runs real Chrome pages with Ash wasm and both
Emscripten threading modes. The pinned hxn checkout lives under tests/.tools, outside restored Cargo target
caches. All use the pinned hxn source/CLI and bounded
runtime invocations; failed runtime logs are retained as CI artifacts.
`tests/ci/run.py` runs each runtime's file, graph, asset and remote checks together.
Its source graph fixtures use a file SDK built with the same profile and
toolchain. The Ash browser fixture explicitly links both native archives.
Release gates separately install the assembled prebuilt ZIPs with Rust disabled.
Native fixture runners set the binding directory on the VM loader search path,
including `PATH` on Windows, matching `hxn check`. Browser profile cleanup is
best-effort; process exit status and the expected fixture success marker still
determine the test result. The mobile runner is a separate local verification;
these CI workflows do not exercise mobile apps or device lifecycle transitions.

## Packaging and commits

Both hxn-file and hxn-assets contain prebuilt native bindings. Retain each
package's LICENSE. Generate file notices with scripts/third_party_notices.py
--package hxn-file --output packages/hxn-file/third-party, and graph notices with
--package hxn-assets-jit-build --output packages/hxn-assets/third-party/native.
Include --extra-manifest <hxn>/Cargo.toml --extra-package hxn-hl in both commands
for generated HashLink ABI notices. Verify inventories with --check. The graph
inventory covers both variants. Retain the Haxe format codec's BSD terms in
hxn-assets/third-party alongside the native inventory. The merged haxelib contains
scalar bindings at its root and JIT bindings under variants/jit; consumers install
one hxn-assets dependency and select through hxn assets build or its Haxe define.

Commit and push only when requested. Commit messages are short, contain no
assistant attribution and cite the full issue ID in a `git-bug:` trailer.
Close issues in git-bug only when their acceptance criteria are met.
Git-bug synchronization is separate from source pushes and requires a request.

## Releases

Both haxelibs share the workspace version and a `v<version>` tag. The release
workflow builds both native packages for desktop, iOS, Android (arm64, and
x86_64 for emulators in CI), threaded Ash
wasm and both Emscripten modes. Desktop and Android also build a JIT variant
inside hxn-assets; iOS and wasm use scalar/vectorized evaluation. It merges platform binaries and checks the archives before
installing both ZIPs for native and real browser consumer checks. Tests use
installed classes and binaries; test fixtures and Rust source
stay outside the packages. Installed graph checks disable Rust tooling. Package skills and notices ship with their owner.
Configure the repository's HAXELIB_PASSWORD secret for the darmie publisher.
A manual workflow run validates and retains archives without publishing.
After main CI passes, tag the same commit. A tag run publishes both archives
and checksums to one GitHub release, then submits hxn-file before hxn-assets.
If submission fails after the GitHub release exists, run Publish existing release
with that immutable tag. It verifies the tag, archive metadata, SHA256SUMS and
GitHub asset digests, then submits only missing Haxelib versions. It does not
rebuild archives or move a release tag. A rejected password stops retries;
transient upload failures are retried after checking for server acceptance.
Refresh released API references and skills on hxn.dev after Haxelib accepts both.

## Logging

Use core `hxn::log` in hxn-file and `hxn.Log` in asset runtime code, with
targets `hxn.file` and `hxn.assets`. Applications own levels and the sink.
Do not log payloads, credentials or remote query strings. Idle native records
need an application-driven flush; frame loops drain with `hxn.Loop.sync()`.
