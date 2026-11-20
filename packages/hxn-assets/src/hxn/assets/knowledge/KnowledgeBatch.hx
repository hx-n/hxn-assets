package hxn.assets.knowledge;

import haxe.Json;
import haxe.io.Bytes;
import hxn.assets.knowledge.KnowledgeSnapshot.KnowledgeData;

/** An immutable, bounded, coalesced update from one scoped source revision. */
class KnowledgeBatch {
	final json:String;

	public final revision:Int;

	public function new(namespace:String, source:String, revision:Int, snapshots:Array<KnowledgeSnapshot>) {
		KnowledgeSnapshot.identifier(namespace, "knowledge namespace");
		KnowledgeSnapshot.identifier(source, "knowledge source");
		if (revision < 1)
			throw "knowledge revision must be positive";
		if (snapshots == null || snapshots.length > 256)
			throw "knowledge batch exceeds 256 snapshots";
		this.revision = revision;
		final selected = new Map<String, KnowledgeData>();
		final schemas = new Map<String, String>();
		for (snapshot in snapshots) {
			final data = snapshot.data(), definition = Json.stringify(data.schema);
			final previous = schemas.get(data.schema.name);
			if (previous != null && previous != definition)
				throw "conflicting knowledge schema definitions";
			schemas.set(data.schema.name, definition);
			// Repeated identities coalesce: a partial snapshot merges into the earlier one.
			final key = KnowledgeSnapshot.key(data.schema.name, data.id), earlier = selected.get(key);
			selected.set(key, earlier == null ? data : KnowledgeSnapshot.merge(earlier, data));
		}
		final keys = [for (key in selected.keys()) key];
		keys.sort(Reflect.compare);
		var partial = false;
		for (data in selected)
			if (data.fields != null)
				partial = true;
		// Version 2 marks a batch carrying partial snapshots; a complete batch stays version 1.
		final header = Json.stringify({
			version: partial ? 2 : 1,
			namespace: namespace,
			source: source,
			revision: revision
		});
		var budget = Bytes.ofString(header).length;
		final encoded:Array<String> = [];
		for (key in keys) {
			final node = KnowledgeSnapshot.encode(selected.get(key));
			budget += Bytes.ofString(node).length + 1;
			if (budget > 1048576)
				throw "knowledge batch exceeds 1 MiB";
			encoded.push(node);
		}
		json = header.substr(0, header.length - 1) + ',"nodes":[' + encoded.join(",") + ']}';
		if (Bytes.ofString(json).length > 1048576)
			throw "knowledge batch exceeds 1 MiB";
	}

	/** Owned UTF-8 JSON for an application-configured local or connected sink. */
	public function toJson():String
		return json;

	/** Detached values for sink implementations. */
	public function data():KnowledgeBatchData {
		final value:Dynamic = Json.parse(json);
		final nodes:Array<Dynamic> = value.nodes;
		return {
			version: value.version,
			namespace: value.namespace,
			source: value.source,
			revision: value.revision,
			nodes: [for (node in nodes) KnowledgeSnapshot.owned(node)]
		};
	}
}

typedef KnowledgeBatchData = {
	var version:Int;
	var namespace:String;
	var source:String;
	var revision:Int;
	var nodes:Array<KnowledgeData>;
}
