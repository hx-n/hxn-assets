# Working on hxn-assets

Read docs/design.md, docs/conventions.md and the skill for the package being
changed. This monorepo contains hxn-file (platform I/O and persistence) and
hxn-assets (asset catalogs and loading). hxnme consumes their public APIs.

This repository owns its git-bug issues. Read `git bug bug` here before
starting on an area. Plans, alternatives, measurements and pending work
belong in its issues, not planning/status documents. Documentation describes
the current implementation.

Keep file operations asynchronous through hxn.Future. Copy guest input before
acknowledgment; page-owned asynchronous work never retains guest pointers.
Bound requests and reads. Keep assets read-only and saves/preferences scoped
to an application. Preserve atomic save replacement and browser transaction
completion. Cores have no runtime dependency or runtime-selecting Cargo features.

Run cargo fmt, clippy and tests. Run HashLink, Ash hybrid/JIT/interpreter,
hxcpp and CPPIA; browser checks use Ash wasm and both hxcpp wasm modes.
Exercise real iOS/Android bundle/APK assets and persistence. Run under timeouts,
repeat concurrent tests, and report unavailable platforms. Windows requires CI.
Run Haxe formatter before committing Haxe changes. Keep test-only hosts and
fixtures under tests/ and outside published CLI tools/assets.

Public tools are hxn CLI plugins, usable from installed haxelibs. Skills use
absolute HTTPS documentation links. Ship pinned dependency notices/source
availability in packages. Update guides/skills with API or workflow changes.
Do not commit, push or publish without the user's request; no AI attribution.
