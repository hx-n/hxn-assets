0.2.1: `hxn.assets.Assets.process(fields)` lets another build macro change the fields of a declaration class first and then run hxn-assets' generation on them. Knowledge snapshots publish only the parts that change, and the graph uses KyuGraph 81bb070.

Install `hxn-assets` for typed assets, remote streams and an embedded knowledge graph. The package includes its KyuGraph engine and prebuilt bindings; Haxe consumers need no Rust toolchain or extra backend package. Metadata and explicit publication opt in to graph projection.

`hxn assets build --jit app.hxml` and `--no-jit` select prebuilt variants. Desktop and Android include both; iOS and wasm use scalar/vectorized queries. Without a flag, the compiler selects available JIT, otherwise scalar. The selection is independent of Ash execution mode.

KnowledgeGraph supports named Cypher parameters, owned decoded results, exact 64-bit values and portable checkpoints saved through hxn-file, including browser IndexedDB. The example combines lore, progress, NPC relationships and world-space bounds, then checks revisions, deletion, replay and restore. Both packages retain their own skills and dependency notices and use core hxn.Log from hxn 0.3.10.

Hosted service, schema migrations, durable outboxes, CRDT synchronization and device transitions remain open work.
