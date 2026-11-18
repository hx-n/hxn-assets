package hxn.assets;

import haxe.Exception;
import hxn.Future;
import hxn.Unit;
import hxn.assets.knowledge.KnowledgeBatch;
import hxn.assets.knowledge.KnowledgeSink;
import hxn.assets.knowledge.KnowledgeSnapshot;

/**
 * Typed knowledge capture and explicit bounded publication on the Haxe event thread.
 *
 * `capture(value)` reads @:identity, @:fact, @:relation and @:spatial selections
 * from a class/typedef annotated with @:knowledge. It returns an owned
 * KnowledgeSnapshot. `remove(value)` captures only schema/identity for a tombstone.
 * These two functions are compile-time macros and require the declared input type.
 * Publication uses a configured KnowledgeSink and explicit increasing revisions.
 * See https://github.com/hx-n/hxn-assets/blob/main/docs/knowledge.md.
 */
class Knowledge {
	final namespace:String;
	final source:String;
	final sink:KnowledgeSink;
	var busy = false;
	var accepted = 0;
	var retryBatch:Null<KnowledgeBatch>;

	public function new(namespace:String, source:String, sink:KnowledgeSink) {
		KnowledgeSnapshot.identifier(namespace, "knowledge namespace");
		KnowledgeSnapshot.identifier(source, "knowledge source");
		if (sink == null)
			throw "knowledge sink is required";
		this.namespace = namespace;
		this.source = source;
		this.sink = sink;
	}

	/** Selects annotated fields once, preserving the declared type and optional asset provenance. */
	public static macro function capture(value:haxe.macro.Expr):haxe.macro.Expr {
		return hxn.assets.macros.KnowledgeMacros.capture(value, false);
	}

	/** Captures the schema and identity for a tombstone; other fields are not read. */
	public static macro function remove(value:haxe.macro.Expr):haxe.macro.Expr {
		return hxn.assets.macros.KnowledgeMacros.capture(value, true);
	}

	/** Publishes a full selected snapshot per changed entity, coalescing repeated identities. */
	public function publish(revision:Int, snapshots:Array<KnowledgeSnapshot>):Future<Unit> {
		if (busy)
			return Future.rejected(new Exception("knowledge publication is already pending"));
		if (retryBatch != null)
			return Future.rejected(new Exception("retry the failed knowledge batch before publishing another"));
		if (revision <= accepted)
			return Future.rejected(new Exception("knowledge revisions must increase"));
		try {
			return send(new KnowledgeBatch(namespace, source, revision, snapshots));
		} catch (error:Exception) {
			return Future.rejected(error);
		}
	}

	/** Replays the identical owned batch after an ambiguous failure; no hidden reconnect. */
	public function retry():Future<Unit> {
		if (busy || retryBatch == null)
			return Future.rejected(new Exception("no failed knowledge batch is ready to retry"));
		return send(retryBatch);
	}

	function send(batch:KnowledgeBatch):Future<Unit> {
		busy = true;
		var operation:Future<Unit>;
		try {
			operation = sink.apply(batch);
			if (operation == null)
				throw new Exception("knowledge sink returned no future");
		} catch (error:Exception) {
			operation = Future.rejected(error);
		}
		return operation.map(_ -> {
			accepted = batch.revision;
			retryBatch = null;
			busy = false;
			return Unit.Nothing;
		}).recover(error -> {
			retryBatch = batch;
			busy = false;
			throw error;
		});
	}
}
