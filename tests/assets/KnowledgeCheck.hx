import haxe.Exception;
import haxe.Json;
import hxn.Future;
import hxn.Unit;
import hxn.assets.Knowledge;
import hxn.assets.knowledge.*;
import Models;

class KnowledgeCheck {
	public static function runChecks():Void {
		var done = false;
		KnowledgeExample.run().then(_ -> done = true, error -> {
			throw error;
		});
		check(done, "reference knowledge sink settles synchronously");
		final loader = new hxn.assets.AssetLoader(new KnowledgeSource(), KnowledgeLiveAssets.catalog());
		var decoded = false;
		KnowledgeLiveAssets.load(loader).then(_ -> {
			final snapshot = Knowledge.capture(KnowledgeLiveAssets.Progress).data();
			check(snapshot.links[0][0] == "ruin", "dynamic JSON reference decoding");
			check(snapshot.asset != null && snapshot.asset.contentId != null, "dynamic asset provenance");
			check(!Reflect.hasField(snapshot.asset, "path"), "transport URI excluded from provenance");
			decoded = true;
		}, error -> {
			throw error;
		});
		check(decoded, "dynamic typed asset decoded before capture");
		KnowledgeLiveAssets.unload();
		loader.close();
		final sink = new MemoryKnowledgeSink();
		final first = new Knowledge("first", "game", sink), second = new Knowledge("second", "game", sink);
		final world:World = {id: "same", name: "First"};
		final snapshot = Knowledge.capture(world);
		world.name = "Second";
		first.publish(1, [snapshot]).await();
		second.publish(1, [Knowledge.capture(world)]).await();
		check(sink.get("first", "World", "same").facts.name == "First", "snapshot copy");
		check(sink.all("first", "World").length == 1 && sink.all("second", "World").length == 1, "namespace isolation");
		check(sink.get("second", "World", "same").facts.name == "Second", "independent namespace values");
		final copy = sink.get("first", "World", "same");
		copy.facts.name = "tampered";
		check(sink.get("first", "World", "same").facts.name == "First", "query result copy");
		sink.apply(new KnowledgeBatch("first", "game", 1, [snapshot])).await();
		fails(() -> sink.apply(new KnowledgeBatch("first", "game", 1, [Knowledge.capture(world)])).await());
		fails(() -> new Knowledge("first", "other-source", sink).publish(2, [snapshot]).await());
		check(sink.get("first", "World", "same").facts.name == "First", "failed ownership update leaves state intact");
		final malformed = snapshot.data();
		malformed.schema.version = 2;
		final conflict = new KnowledgeSnapshot(malformed.schema, malformed.id, malformed.facts, malformed.links, malformed.bounds);
		fails(() -> first.publish(2, [conflict]).await());
		check(sink.get("first", "World", "same").facts.name == "First", "schema failure is atomic");
		// A failed writer retains precisely its failed snapshot until retry.
		final delayed = new DelayedSink();
		final writer = new Knowledge("pending", "game", delayed);
		var settled = false;
		writer.publish(1, [snapshot]).then(_ -> settled = true, _ -> settled = true);
		check(!settled, "pending publication");
		fails(() -> writer.publish(2, [snapshot]).await());
		delayed.fail();
		check(settled, "publication failure delivered");
		world.name = "New value after failure";
		fails(() -> writer.publish(2, [Knowledge.capture(world)]).await());
		final retry = writer.retry();
		check(delayed.jsons.length == 2 && delayed.jsons[0] == delayed.jsons[1], "retry retains identical bytes");
		delayed.succeed();
		retry.await();
		fails(() -> writer.publish(1, [snapshot]).await());
		final coalesced = new KnowledgeBatch("batch", "source", 1, [snapshot, Knowledge.capture(world)]);
		check(coalesced.data().nodes.length == 1 && coalesced.data().nodes[0].facts.name == world.name, "coalesced latest identity");
		fails(() -> new KnowledgeBatch("x", "x", 1, [for (_ in 0...257) snapshot]));
		final text = StringTools.rpad("", "x", 60000);
		final large:LargeKnowledge = {id: "large", messages: [text, text, text, text, text]};
		fails(() -> Knowledge.capture(large));
		final records = [
			for (index in 0...18) {
				final item:World = {id: Std.string(index), name: text};
				Knowledge.capture(item);
			}
		];
		fails(() -> new KnowledgeBatch("large", "source", 1, records));
		final npc:Npc = {
			id: "npc",
			name: "Name",
			goal: "Goal",
			memories: [],
			knowledge: ["ruin"],
			world: "same",
			position: {x: Math.NaN, y: 0, z: 0},
			privatePrompt: "private"
		};
		fails(() -> Knowledge.capture(npc));
		npc.position.x = 0;
		npc.knowledge = [for (_ in 0...1025) "ruin"];
		fails(() -> Knowledge.capture(npc));
		npc.knowledge = ["ruin"];
		final spatial = Knowledge.capture(npc).data();
		final restored = new KnowledgeSnapshot(spatial.schema, spatial.id, spatial.facts, spatial.links, spatial.bounds);
		check(restored.data().links[0][0] == "ruin", "typed relationships survive provider roundtrip");
		spatial.bounds.world = "another-world";
		fails(() -> new KnowledgeSnapshot(spatial.schema, spatial.id, spatial.facts, spatial.links, spatial.bounds));
		spatial.bounds.world = "same";
		spatial.bounds.units = "different-unit";
		fails(() -> new KnowledgeSnapshot(spatial.schema, spatial.id, spatial.facts, spatial.links, spatial.bounds));
		npc.id = "";
		fails(() -> Knowledge.capture(npc));
		final object = new ReadOnce();
		final captured = Knowledge.capture(object);
		check(object.reads == 1 && captured.data().facts.name == "Read once", "selected getter read once");
		Knowledge.remove(object);
		check(object.reads == 1, "tombstone reads only identity");
		Sys.println("PASS: knowledge typed capture, copies, namespaces, revisions, bounded publication and exact retry");
	}

	static function main():Void
		runChecks();

	static function check(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function fails(call:() -> Dynamic):Void {
		var failed = false;
		try {
			call();
		} catch (_:Dynamic) {
			failed = true;
		}
		check(failed, "expected knowledge failure");
	}
}

@:knowledge("ReadOnce")
private class ReadOnce {
	@:identity public var id = "object";
	@:fact public var name(get, never):String;
	public var reads = 0;

	public function new() {}

	function get_name():String {
		reads++;
		return "Read once";
	}
}

private class DelayedSink implements KnowledgeSink {
	public final jsons:Array<String> = [];

	var pending:Future<Unit>;

	public function new() {}

	public function apply(batch:KnowledgeBatch):Future<Unit> {
		jsons.push(batch.toJson());
		pending = new Future<Unit>();
		return pending;
	}

	public function fail():Void {
		@:privateAccess pending.settle(null, new Exception("lost acknowledgement"));
	}

	public function succeed():Void {
		@:privateAccess pending.settle(Unit.Nothing, null);
	}
}

@:build(hxn.assets.Assets.build())
private class KnowledgeLiveAssets {
	@:asset("knowledge.test.progress", "knowledge/progress.json") @:dynamicAsset @:contentAddressed
	public static var Progress:QuestProgress;
}

private class KnowledgeSource implements hxn.assets.AssetSource {
	public function new() {}

	public function read(path:String):Future<haxe.io.Bytes> {
		return Future.resolved(haxe.io.Bytes.ofString('{"id":"player-1/ruin","player":"player-1","state":"active","lore":"ruin"}\n'));
	}
}

@:knowledge("LargeKnowledge")
private typedef LargeKnowledge = {
	@:identity var id:String;
	@:fact var messages:Array<String>;
}
