import hxn.Future;
import hxn.Unit;
import hxn.assets.Knowledge;
import hxn.assets.knowledge.*;
import Models;

/** One semantic model shared by embedded assets, live state and any configured sink. */
class KnowledgeExample {
	public static final namespace = "campaign/one";

	public static function run(?destination:KnowledgeSink):Future<Array<KnowledgeBatch>> {
		final memory = new MemoryKnowledgeSink();
		final batches:Array<KnowledgeBatch> = [];
		final sink:KnowledgeSink = new RecordingSink(memory, batches, destination);
		final knowledge = new Knowledge(namespace, "game", sink);
		final north:World = {id: "north", name: "Northern valley"};
		final dream:World = {id: "dream", name: "Dream world"};
		final sage:Npc = {
			id: "sage",
			name: "Mira",
			goal: "Protect the ruin",
			memories: ["The seal is broken"],
			knowledge: ["ruin"],
			world: "north",
			position: {x: 3, y: 2, z: 0},
			privatePrompt: "Never exported"
		};
		final distant:Npc = {
			id: "distant",
			name: "Far away",
			goal: "Travel",
			memories: [],
			knowledge: ["ruin"],
			world: "north",
			position: {x: 100, y: 100, z: 0},
			privatePrompt: "Hidden"
		};
		final stranger:Npc = {
			id: "stranger",
			name: "Uninformed",
			goal: "Trade",
			memories: [],
			knowledge: [],
			world: "north",
			position: {x: 2, y: 2, z: 0},
			privatePrompt: "Hidden"
		};
		final dreamer:Npc = {
			id: "dreamer",
			name: "Elsewhere",
			goal: "Sleep",
			memories: [],
			knowledge: ["ruin"],
			world: "dream",
			position: {x: 1, y: 1, z: 0},
			privatePrompt: "Hidden"
		};
		final progress:QuestProgress = {
			id: "player-1/ruin",
			player: "player-1",
			state: "active",
			lore: "ruin"
		};
		final authored = Knowledge.capture(GameAssets.Ruin);
		require(authored.data().asset != null && authored.data().asset.contentId != null, "automatic asset provenance");
		require(GameAssets.Ruin.title == "The sealed ruin", "decoded embedded lore");
		return knowledge.publish(1, [
			                  authored,    Knowledge.capture(north),   Knowledge.capture(dream),   Knowledge.capture(sage),
			Knowledge.capture(distant), Knowledge.capture(stranger), Knowledge.capture(dreamer), Knowledge.capture(progress)
		])
			.flatMap(_ -> {
				require(candidates(memory).join(",") == "sage", "lore + progress + relationship + world-space query");
				require(Reflect.field(memory.get(namespace, "Npc", "sage").facts, "privatePrompt") == null, "unannotated data excluded");
				sage.position.x = 1000;
				sage.knowledge = [];
				sage.goal = "Follow the player";
				sage.memories.push("The player restored the seal");
				progress.state = "complete";
				require(memory.get(namespace, "Npc", "sage").bounds.minX == 3, "captured state owns its values");
				return knowledge.publish(2, [Knowledge.capture(sage), Knowledge.capture(progress)]);
			})
			.flatMap(_ -> {
				require(candidates(memory).length == 0, "live progress and spatial updates");
				require(memory.related(namespace, "Npc", "sage", "KNOWS").length == 0, "replaced relationships removed");
				require(memory.all(namespace, "Npc").length == 4, "semantic identity survives mutation");
				sage.position.x = 3;
				sage.knowledge = ["ruin"];
				progress.state = "active";
				return knowledge.publish(3, [Knowledge.capture(sage), Knowledge.capture(progress)]);
			})
			.flatMap(_ -> {
				require(candidates(memory).join(",") == "sage", "relationship restored");
				progress.state = "complete";
				return knowledge.publish(4, [Knowledge.capture(progress)]);
			})
			.flatMap(_ -> {
				require(candidates(memory).length == 0, "progress independently gates NPC eligibility");
				progress.state = "active";
				return knowledge.publish(5, [Knowledge.capture(progress)]);
			})
			.flatMap(_ -> {
				require(candidates(memory).join(",") == "sage", "active progress restores NPC eligibility");
				return knowledge.publish(6, [Knowledge.remove(GameAssets.Ruin)]);
			})
			.flatMap(_ -> {
				require(candidates(memory).length == 0, "tombstoned knowledge excluded");
				return memory.apply(batches[0]);
			})
			.map(_ -> {
				require(memory.get(namespace, "Lore", "ruin") == null, "stale batch cannot resurrect deleted lore");
				return batches;
			});
	}

	static function candidates(graph:MemoryKnowledgeSink):Array<String> {
		final progress = graph.get(namespace, "QuestProgress", "player-1/ruin");
		if (progress == null || progress.facts.state != "active")
			return [];
		final relevant = graph.related(namespace, "QuestProgress", progress.id, "ABOUT");
		final nearby = graph.within(namespace, "Npc", {
			world: "north",
			units: "metre",
			minX: 0,
			minY: 0,
			minZ: -1,
			maxX: 10,
			maxY: 10,
			maxZ: 1
		});
		return [
			for (npc in nearby)
				if (graph.related(namespace, "Npc", npc.id, "KNOWS").filter(lore -> relevant.filter(item -> item.id == lore.id).length > 0).length > 0) npc.id
		];
	}

	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function main():Void {
		run().then(batches -> {
			#if hxn_knowledge_export
			sys.io.File.saveContent(Sys.args()[0], "[" + [for (batch in batches) batch.toJson()].join(",") + "]");
			#end
			Sys.println("PASS: knowledge lore, quest progress, NPC behavior, relationships and spatial updates");
		}, error -> {
			throw error;
		});
	}
}

private class RecordingSink implements KnowledgeSink {
	final memory:MemoryKnowledgeSink;
	final batches:Array<KnowledgeBatch>;
	final destination:Null<KnowledgeSink>;

	public function new(memory:MemoryKnowledgeSink, batches:Array<KnowledgeBatch>, ?destination:KnowledgeSink) {
		this.memory = memory;
		this.batches = batches;
		this.destination = destination;
	}

	public function apply(batch:KnowledgeBatch):Future<Unit>
		return memory.apply(batch).flatMap(_ -> destination == null ? Future.resolved(Unit.Nothing) : destination.apply(batch)).map(_ -> {
			batches.push(batch);
			return Unit.Nothing;
		});
}
