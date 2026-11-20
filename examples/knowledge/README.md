# Semantic game knowledge

Models.hx annotates lore, worlds, NPC behavior context and quest progress.
GameAssets.hx embeds typed lore from JSON. KnowledgeExample.run() returns a
future and queries nearby NPCs who know lore relevant to the player's active quest.

| Revision | Change | Eligible NPC IDs |
|---|---|---|
| 1 | Lore, worlds, NPCs and active progress | sage |
| 2 | Sage moves away, loses the lore relation; progress completes | none |
| 3 | Sage returns; knowledge and active progress are restored | sage |
| 4 | Only quest progress completes | none |
| 5 | Quest becomes active again | sage |
| 6 | Lore is tombstoned | none |

NPCs in another world, distant NPCs and nearby uninformed NPCs are excluded.
The unannotated privatePrompt field is never captured. Replaying revision 1
after revision 6 does not restore deleted lore. The embedded KyuGraph example
applies the same batches and executes a parameterized relationship/AABB query,
including duplicate/stale delivery, exact 64-bit parameters and a checkpoint
saved and reloaded through hxn-file.

With hxn-assets and its dependencies installed, compile from the repository root
with `haxe examples/knowledge/example.hxml`, then run
`ash target/knowledge-example.hl`. In an existing application, add this example
directory as a class path and call KnowledgeExample.run from its normal Haxe
entry point. This portable example uses MemoryKnowledgeSink. To run the embedded engine,
compile `hxn assets build --jit examples/knowledge/graph.hxml` (or `--no-jit`),
then run `ash target/embedded-graph.hl`. The installed haxelib supplies both
implementations on supported targets; consumers need no Rust toolchain.

Repository verification uses `python3 tests/knowledge/run.py --adapter`.
The installed consumer runner also checks scalar/JIT selection and checkpoint
interchange with Rust disabled. These are
test runners, not installed consumer commands. The portable checks also run in
the native, browser and mobile file/assets fixtures.

See [knowledge metadata](../../docs/knowledge.md) for the contract and limits.
