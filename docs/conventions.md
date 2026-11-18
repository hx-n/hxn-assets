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

The file fixture is tests/check/Main.hx, selected by hxn-file's Cargo metadata.
From packages/hxn-file, use `hxn run hl`, `hxn run hl --vm ash`, Ash's JIT and
interpreter options, `hxn run cpp` and `hxn run cppia`. Browser checks use
`hxn run hl --wasm --threads --browser --vm <ash>` and
`hxn run cpp --wasm --browser`, with and without `--threads`.
Use an Ash version supporting wasm native libraries and page agents.

Run `python3 tests/assets/run.py --hxn <hxn>` from the workspace root for the
catalog/cache suite, typed embedded/dynamic values, annotation compile errors,
exact staged/runtime catalogs,
inlining/dead-code elimination, compiler-server reuse and asset-edit invalidation.
The runner uses an Ash executable (override with `--ash`) and isolated temporary
output beneath target/. `tests/assets/runtimes.py` runs the real FileSource and
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
Emscripten threading modes. All use the pinned hxn source/CLI and bounded
runtime invocations; failed runtime logs are retained as CI artifacts.
`tests/ci/run.py` runs each runtime's file, asset and remote checks together.
Native fixture runners set the binding directory on the VM loader search path,
including `PATH` on Windows, matching `hxn check`. Browser profile cleanup is
best-effort; process exit status and the expected fixture success marker still
determine the test result. The mobile runner is a separate local verification;
these CI workflows do not exercise mobile apps or device lifecycle transitions.

## Packaging and commits

hxn-file is the native package; hxn-assets is a separate Haxe haxelib depending
on it. Retain each package's LICENSE. Generate notices from the pinned Cargo
graph using scripts/third_party_notices.py; ship hxn-file's third-party directory
with its binary package, including applicable source archives. Run the script's
`--check` before releasing. A package directory generated by hxn must receive
these notices before archiving. Verify them from the workspace root with
`python3 scripts/third_party_notices.py --output packages/hxn-file/third-party --check`.
hxn-assets also retains its Haxe format codec's BSD terms under its own third-party directory.

Commit and push only when requested. Commit messages are short, contain no
assistant attribution and cite the full issue ID in a `git-bug:` trailer.
Close issues in git-bug only when their acceptance criteria are met.
Git-bug synchronization is separate from source pushes and requires a request.

## Logging

Use core `hxn::log` in hxn-file and `hxn.Log` in asset runtime code, with
targets `hxn.file` and `hxn.assets`. Applications own levels and the sink.
Do not log payloads, credentials or remote query strings. Idle native records
need an application-driven flush; frame loops drain with `hxn.Loop.sync()`.
