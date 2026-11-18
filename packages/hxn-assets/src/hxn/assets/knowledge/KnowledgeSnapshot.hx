package hxn.assets.knowledge;

import haxe.Json;
import haxe.io.Bytes;

/** Owned selected data captured by Knowledge.capture, independent of later edits. */
class KnowledgeSnapshot {
	final json:String;

	/** Low-level provider boundary; application code uses Knowledge.capture/remove. */
	public function new(schema:KnowledgeSchema, id:String, facts:Dynamic, links:Array<Array<String>>, bounds:Null<KnowledgeBounds>,
			?asset:KnowledgeAssetOrigin, deleted:Bool = false) {
		identifier(id, "knowledge identity");
		name(schema.name);
		name(schema.identity);
		if (schema.version < 1 || schema.facts.length + schema.relations.length > 64)
			throw "invalid knowledge schema version or field count";
		var budget = Bytes.ofString(Json.stringify(schema)).length;
		final names = [schema.identity];
		for (field in schema.facts) {
			name(field.name);
			if (names.indexOf(field.name) >= 0)
				throw "duplicate knowledge field";
			names.push(field.name);
			if (["string", "int", "float", "bool", "string[]", "int[]", "float[]", "bool[]"].indexOf(field.kind) < 0)
				throw "invalid knowledge fact kind";
			if (!deleted) {
				budget += value(Reflect.field(facts, field.name), field.kind, field.nullable);
				if (budget > 262144)
					throw "knowledge snapshot exceeds 256 KiB";
			}
		}
		if (!deleted && Reflect.fields(facts).length != schema.facts.length)
			throw "knowledge facts do not match the schema";
		if (!deleted && links.length != schema.relations.length)
			throw "knowledge links do not match the schema";
		if (!deleted)
			links = [
				for (ids in links) {
					if (ids == null || ids.length > 1024) throw "invalid knowledge relationship list";
					ids.copy();
				}
			];
		for (index in 0...schema.relations.length) {
			final relation = schema.relations[index];
			name(relation.name);
			name(relation.target);
			if (names.indexOf(relation.name) >= 0)
				throw "duplicate knowledge relation";
			names.push(relation.name);
			if (!deleted) {
				final ids = links[index];
				if (ids == null
					|| ids.length > 1024
					|| (!relation.many && ids.length > 1)
					|| (!relation.many && !relation.nullable && ids.length != 1))
					throw "invalid knowledge relationship cardinality";
				for (id in ids) {
					identifier(id, "relationship target");
					budget += Bytes.ofString(Json.stringify(id)).length + 1;
					if (budget > 262144)
						throw "knowledge snapshot exceeds 256 KiB";
				}
				ids.sort(Reflect.compare);
				final unique:Array<String> = [];
				for (id in ids)
					if (unique.length == 0 || unique[unique.length - 1] != id)
						unique.push(id);
				links[index] = unique;
			}
		}
		if (!deleted && (bounds != null) != (schema.spatial != null))
			throw "knowledge spatial data does not match the schema";
		if (schema.spatial != null) {
			identifier(schema.spatial.units, "schema spatial units");
			final selected = schema.relations.filter(relation -> relation.name == schema.spatial.relation);
			if (selected.length != 1 || selected[0].many || selected[0].nullable)
				throw "invalid spatial world relationship";
		}
		if (bounds != null) {
			final index = [for (relation in schema.relations) relation.name].indexOf(schema.spatial.relation);
			if (bounds.units != schema.spatial.units || links[index][0] != bounds.world)
				throw "spatial context differs from its relationship schema";
			identifier(bounds.world, "spatial world");
			identifier(bounds.units, "spatial units");
			for (value in [bounds.minX, bounds.minY, bounds.minZ, bounds.maxX, bounds.maxY, bounds.maxZ])
				if (!Math.isFinite(value))
					throw "knowledge bounds must be finite";
			if (bounds.minX > bounds.maxX || bounds.minY > bounds.maxY || bounds.minZ > bounds.maxZ)
				throw "knowledge bounds must be ordered";
		}
		var origin:Null<KnowledgeAssetOrigin> = null;
		if (asset != null) {
			identifier(asset.address, "asset provenance address");
			if (asset.contentId != null && !~/^sha256:[0-9a-f]{64}$/.match(asset.contentId))
				throw "invalid asset provenance content ID";
			origin = {address: asset.address, contentId: asset.contentId};
		}
		json = Json.stringify({
			schema: schema,
			id: id,
			facts: deleted ? {} : facts,
			links: deleted ? [] : links,
			bounds: deleted ? null : bounds,
			asset: origin,
			deleted: deleted
		});
		if (Bytes.ofString(json).length > 262144)
			throw "knowledge snapshot exceeds 256 KiB";
	}

	/** A detached wire value; sinks cannot mutate the snapshot. */
	public function data():KnowledgeData
		return owned(Json.parse(json));

	@:allow(hxn.assets.knowledge.KnowledgeBatch)
	@:allow(hxn.assets.knowledge.MemoryKnowledgeSink)
	static function owned(value:Dynamic):KnowledgeData {
		// JSON arrays are dynamic containers; rebuild typed string lists before native array operations.
		final raw:Array<Dynamic> = value.links;
		final links:Array<Array<String>> = [];
		for (row in raw) {
			final source:Array<Dynamic> = row;
			final targets:Array<String> = [];
			for (id in source) {
				final text:String = id;
				targets.push(text);
			}
			links.push(targets);
		}
		return {
			schema: value.schema,
			id: value.id,
			facts: value.facts,
			links: links,
			bounds: value.bounds,
			asset: value.asset,
			deleted: value.deleted
		};
	}

	public static function key(schema:String, id:String):String
		return Json.stringify([schema, id]);

	public static function identifier(value:String, description:String):Void {
		if (value == null
			|| value.length == 0
			|| value.length > 256
			|| Bytes.ofString(value).length > 256
			|| value.indexOf("\x00") >= 0)
			throw 'invalid $description';
	}

	public static function name(value:String):Void {
		if (value == null || !~/^[A-Za-z][A-Za-z0-9_]{0,63}$/.match(value))
			throw "invalid knowledge schema/field name";
	}

	static function value(value:Dynamic, kind:String, nullable:Bool):Int {
		if (value == null) {
			if (!nullable)
				throw "missing non-null knowledge fact";
			return 4;
		}
		if (StringTools.endsWith(kind, "[]")) {
			if (!Std.isOfType(value, Array))
				throw "knowledge fact must be an array";
			final values:Array<Dynamic> = value;
			if (values.length > 1024)
				throw "knowledge fact array exceeds 1024 values";
			var total = 2;
			for (entry in values) {
				total += KnowledgeSnapshot.value(entry, kind.substr(0, kind.length - 2), false) + 1;
				if (total > 262144)
					throw "knowledge snapshot exceeds 256 KiB";
			}
			return total;
		}
		final valid = switch (kind) {
			case "string": Std.isOfType(value, String) && (cast value : String).length <= 65536
					&& Bytes.ofString(cast value).length <= 65536;
			case "int": Std.isOfType(value, Int);
			case "float": Std.isOfType(value, Float) && Math.isFinite(value);
			case "bool": Std.isOfType(value, Bool);
			case _: false;
		};
		if (!valid)
			throw 'invalid knowledge fact ($kind)';
		return Bytes.ofString(Json.stringify(value)).length;
	}
}

/** Versioned wire data selected by knowledge metadata, without live object pointers. */
typedef KnowledgeData = {
	var schema:KnowledgeSchema;
	var id:String;
	var facts:Dynamic;
	var links:Array<Array<String>>;
	var bounds:Null<KnowledgeBounds>;
	var asset:Null<KnowledgeAssetOrigin>;
	var deleted:Bool;
}

/** Source identity only; transport URIs, headers and credentials are excluded. */
typedef KnowledgeAssetOrigin = {
	var address:String;
	@:optional var contentId:String;
}
