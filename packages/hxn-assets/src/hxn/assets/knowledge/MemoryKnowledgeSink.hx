package hxn.assets.knowledge;

import haxe.Exception;
import haxe.Json;
import hxn.Future;
import hxn.Unit;
import hxn.assets.knowledge.KnowledgeSnapshot.KnowledgeData;

/** Portable reference sink and relationship/AABB queries; no spatial index is implied. */
class MemoryKnowledgeSink implements KnowledgeSink {
	var nodes = new Map<String, String>();
	final schemas = new Map<String, String>();
	final revisions = new Map<String, {revision:Int, json:String}>();

	public function new() {}

	public function apply(batch:KnowledgeBatch):Future<Unit> {
		try {
			final data = batch.data(), owner = Json.stringify([data.namespace, data.source]);
			final previous = revisions.get(owner);
			if (previous != null && data.revision <= previous.revision) {
				if (data.revision == previous.revision && batch.toJson() != previous.json)
					throw "knowledge revision reused with different data";
				return Future.resolved(Unit.Nothing);
			}
			final nextSchemas = schemas.copy();
			for (node in data.nodes) {
				final name = node.schema.name, definition = Json.stringify(node.schema);
				if (nextSchemas.exists(name) && nextSchemas.get(name) != definition)
					throw "knowledge schema changed without migration";
				nextSchemas.set(name, definition);
			}
			final next = nodes.copy();
			for (node in data.nodes) {
				for (relation in node.schema.relations)
					if (!nextSchemas.exists(relation.target))
						throw 'unknown knowledge relationship schema ${relation.target}; publish its schema first';
				final key = scoped(data.namespace, node.schema.name, node.id);
				final existing = next.get(key);
				if (existing != null && Json.parse(existing).source != data.source)
					throw "knowledge entity belongs to another source";
				next.set(key, Json.stringify({
					value: node,
					namespace: data.namespace,
					source: data.source,
					revision: data.revision
				}));
			}
			nodes = next;
			for (key in nextSchemas.keys())
				schemas.set(key, nextSchemas.get(key));
			revisions.set(owner, {revision: data.revision, json: batch.toJson()});
			return Future.resolved(Unit.Nothing);
		} catch (error:Exception)
			return Future.rejected(error);
	}

	/** Detached current values; missing and tombstoned entities return null. */
	public function get(namespace:String, schema:String, id:String):Null<KnowledgeData> {
		final entry = nodes.get(scoped(namespace, schema, id));
		if (entry == null)
			return null;
		final value:KnowledgeData = KnowledgeSnapshot.owned(Json.parse(entry).value);
		return value.deleted ? null : value;
	}

	public function all(namespace:String, schema:String):Array<KnowledgeData> {
		final result:Array<KnowledgeData> = [];
		for (entry in nodes) {
			final stored:Dynamic = Json.parse(entry);
			final node:KnowledgeData = KnowledgeSnapshot.owned(stored.value);
			if (stored.namespace == namespace && node.schema.name == schema && !node.deleted)
				result.push(node);
		}
		result.sort((a, b) -> Reflect.compare(a.id, b.id));
		return result;
	}

	public function related(namespace:String, schema:String, id:String, relationship:String):Array<KnowledgeData> {
		final node = get(namespace, schema, id), result:Array<KnowledgeData> = [];
		if (node == null)
			return result;
		for (index in 0...node.schema.relations.length) {
			final relation = node.schema.relations[index];
			if (relation.name == relationship)
				for (target in node.links[index]) {
					final value = get(namespace, relation.target, target);
					if (value != null)
						result.push(value);
				}
		}
		return result;
	}

	/** Inclusive AABB overlap in one world/coordinate space and unit system. */
	public function within(namespace:String, schema:String, area:KnowledgeBounds):Array<KnowledgeData> {
		return all(namespace, schema).filter(node -> {
			final b = node.bounds;
			return b != null && b.world == area.world && b.units == area.units && b.minX <= area.maxX && b.maxX >= area.minX && b.minY <= area.maxY
				&& b.maxY >= area.minY && b.minZ <= area.maxZ && b.maxZ >= area.minZ;
		});
	}

	static function scoped(namespace:String, schema:String, id:String):String
		return Json.stringify([namespace, schema, id]);
}
