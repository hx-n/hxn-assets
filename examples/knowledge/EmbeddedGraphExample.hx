import hxn.Future;
import hxn.Unit;
import hxn.file.Storage;
import hxn.file.StorageOptions;
import hxn.assets.KnowledgeGraph;
import hxn.assets.knowledge.KnowledgeBatch;
import hxn.assets.knowledge.KnowledgeSink;

/** Runs the authored lore and live-state scenario directly through the Haxe graph API. */
class EmbeddedGraphExample {
	public static function run(?options:StorageOptions, ?expectedJit:Bool):Future<Unit> {
		var graph:KnowledgeGraph = null;
		var initial:KnowledgeBatch = null;
		final files = new Storage("org.hxn.knowledge.example", options);
		return KnowledgeGraph.open()
			.flatMap(value -> {
				graph = value;
				if (expectedJit != null && graph.jit != expectedJit)
					throw "wrong packaged KyuGraph build";
				Sys.println("graph JIT: " + graph.jit);
				return KnowledgeExample.run(new GraphAssertions(graph));
			})
			.flatMap(batches -> {
				initial = batches[0];
				return graph.apply(initial);
			})
			.flatMap(_ -> concurrent(graph))
			.flatMap(_ -> graph.query("RETURN 9007199254740993 AS precise"))
			.flatMap(result -> {
				if (haxe.Int64.toStr(cast result.rows[0][0]) != "9007199254740993")
					throw "graph integer precision lost";
				return graph.query("RETURN $precise AS precise, $labels AS labels",
					{precise: haxe.Int64.parseString("9007199254740993"), labels: ["lore", "progress"]});
			})
			.flatMap(result -> {
				if (haxe.Int64.toStr(cast result.rows[0][0]) != "9007199254740993" || result.rows[0][1][1] != "progress")
					throw "typed query parameter was not preserved";
				return graph.save(files, "graph/checkpoint.json");
			})
			.flatMap(_ -> graph.close())
			.flatMap(_ -> KnowledgeGraph.load(files, "graph/checkpoint.json"))
			.flatMap(restored -> {
				graph = restored;
				return graph.query("MATCH (npc:Npc) WHERE npc._hxn_deleted = false RETURN npc.id");
			})
			.flatMap(result -> {
				if (result.rows.length != 4)
					throw "restored graph lost entities";
				return graph.apply(initial);
			})
			.flatMap(_ -> graph.query("MATCH (lore:Lore) WHERE lore._hxn_deleted = false RETURN lore.id"))
			.flatMap(result -> {
				if (result.rows.length != 0)
					throw "checkpoint lost revision/tombstone protection";
				return graph.close();
			})
			.map(_ -> {
				files.close();
				return Unit.Nothing;
			});
	}

	static function concurrent(graph:KnowledgeGraph):Future<Unit> {
		var complete = Future.resolved(Unit.Nothing);
		for (_ in 0...4)
			complete = complete.flatMap(_ -> {
				final requests = [for (i in 0...6) graph.query("RETURN $value AS value", {value: i})];
				var result = Future.resolved(Unit.Nothing);
				for (i in 0...requests.length) {
					final index = i;
					result = result.flatMap(_ -> requests[index].map(query -> {
						if (query.rows[0][0] != index)
							throw "concurrent graph query lost its owned input";
						return Unit.Nothing;
					}));
				}
				return result;
			});
		return complete;
	}

	static function main():Void {
		run().then(_ -> {
			Sys.println("PASS: embedded lore, progress, NPC relationships, spatial queries and replay");
			hxn.Loop.exit(0);
		}, error -> {
			Sys.stderr().writeString(Std.string(error) + "\n");
			Sys.exit(1);
		});
	}
}

private class GraphAssertions implements KnowledgeSink {
	final graph:KnowledgeGraph;

	public function new(graph:KnowledgeGraph) {
		this.graph = graph;
	}

	public function apply(batch:KnowledgeBatch):Future<Unit> {
		final query = "MATCH (npc:Npc)-[:Npc__KNOWS__Lore]->(lore:Lore)<-[:QuestProgress__ABOUT__Lore]-(progress:QuestProgress)\n            WHERE npc._hxn_namespace = $namespace AND progress.player = $player\n              AND npc._hxn_deleted = false AND lore._hxn_deleted = false AND progress._hxn_deleted = false\n              AND progress.state = $state AND npc._hxn_world = $world AND npc._hxn_units = $units\n              AND npc._hxn_min_x <= $max_x AND npc._hxn_max_x >= $min_x\n              AND npc._hxn_min_y <= $max_y AND npc._hxn_max_y >= $min_y\n              AND npc._hxn_min_z <= $max_z AND npc._hxn_max_z >= $min_z\n            RETURN npc.id";
		return graph.apply(batch).flatMap(_ -> graph.query(query, {
			namespace: KnowledgeExample.namespace,
			player: "player-1",
			state: "active",
			world: "north",
			units: "metre",
			min_x: 0.0,
			max_x: 10.0,
			min_y: 0.0,
			max_y: 10.0,
			min_z: -1.0,
			max_z: 1.0
		})).flatMap(result -> {
			final expected = batch.revision == 1 || batch.revision == 3 || batch.revision == 5 || batch.revision == 6;
			if (result.rows.length != (expected ? 1 : 0) || (expected && result.rows[0][0] != "sage"))
				throw 'wrong graph result at revision ${batch.revision}';
			Sys.println('graph revision ${batch.revision}: ' + (expected ? "sage" : "none"));
			return graph.apply(batch);
		});
	}
}
