---
name: hxn-file
description: Use or change hxn-file bundled reads, application saves, preferences, native roots and browser persistence across hxn runtimes.
---

Use `hxn.file.Storage` for bundled reads and application-scoped saves/preferences.
Operations return hxn.Future; use callbacks on the browser page thread. Close
Storage when finished. Started operations retain their state; a FileSource
borrows its Storage rather than taking ownership.

Read the [file API](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/README.md)
and [design](https://github.com/hx-n/hxn-assets/blob/main/docs/design.md) for roots,
limits, browser transport and persistence semantics. The compiler init macro
stages selected assets; an Android application host initializes ndk-context and
mobile packaging includes actual bundle/APK assets. Keep test hosts under tests/.

Native and browser writes copy inputs before returning. Browser results stay
page-owned until copied synchronously into Rust; never retain transient guest
pointers for asynchronous callbacks. Resolve paths through scoped roots and
settle writes only after the persistence operation commits.

Use this repository's git-bug tracker for its work. Follow the
[verification and packaging conventions](https://github.com/hx-n/hxn-assets/blob/main/docs/conventions.md).
Retain the [native dependency notices](https://github.com/hx-n/hxn-assets/blob/main/packages/hxn-file/third-party/NOTICES.md)
with redistributed binaries. A compile-only mobile result is not a runtime pass.
