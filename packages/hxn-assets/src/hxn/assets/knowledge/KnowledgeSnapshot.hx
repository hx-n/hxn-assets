package hxn.assets.knowledge;

import haxe.Json;
import haxe.io.Bytes;

/** Owned selected data captured by Knowledge.capture, independent of later edits. */
class KnowledgeSnapshot {
	final json:String;

	/**
		Low-level provider boundary; application code uses Knowledge.capture, captureFields and remove.
		`fields` makes the snapshot partial: it names the facts and relationships it carries, and
		`links` holds an empty list for every relationship it does not select.
	**/
	public function new(schema:KnowledgeSchema, id:String, facts:Dynamic, links:Array<Array<String>>, bounds:Null<KnowledgeBounds>,
			?asset:KnowledgeAssetOrigin, deleted:Bool = false, ?fields:Array<String>) {
		identifier(id, "knowledge identity");
		if (fields != null) {
			if (deleted || fields.length == 0)
				throw "a partial knowledge snapshot selects at least one field and is not a tombstone";
			final declared = [for (fact in schema.facts) fact.name].concat([for (relation in schema.relations) relation.name]);
			final unique:Array<String> = [];
			for (field in fields) {
				if (declared.indexOf(field) < 0 || unique.indexOf(field) >= 0)
					throw "invalid partial knowledge selection";
				unique.push(field);
			}
			fields = unique;
			fields.sort(Reflect.compare);
		}
		final selects = (name:String) -> fields == null || fields.indexOf(name) >= 0;
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
			if (!deleted && selects(field.name)) {
				budget += value(Reflect.field(facts, field.name), field.kind, field.nullable);
				if (budget > 262144)
					throw "knowledge snapshot exceeds 256 KiB";
			}
		}
		if (!deleted && Reflect.fields(facts).length != schema.facts.filter(fact -> selects(fact.name)).length)
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
			if (!deleted && !selects(relation.name)) {
				if (links[index].length != 0)
					throw "an unselected knowledge relationship carries targets";
			} else if (!deleted) {
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
		if (!deleted && (bounds != null) != (schema.spatial != null && selects(schema.spatial.relation)))
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
		// Only a partial snapshot carries `fields`, so a complete one keeps its version-1 encoding.
		// Literal objects keep one key order on every target, which replay digests depend on.
		json = fields == null ? Json.stringify({
			schema: schema,
			id: id,
			facts: deleted ? {} : facts,
			links: deleted ? [] : links,
			bounds: deleted ? null : bounds,
			asset: origin,
			deleted: deleted
		}) : Json.stringify({
			schema: schema,
			id: id,
			facts: facts,
			links: links,
			bounds: bounds,
			asset: origin,
			deleted: false,
			fields: fields
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
		if (value.fields == null)
			return {
				schema: value.schema,
				id: value.id,
				facts: value.facts,
				links: links,
				bounds: value.bounds,
				asset: value.asset,
				deleted: value.deleted
			};
		final raw:Array<Dynamic> = value.fields;
		return {
			schema: value.schema,
			id: value.id,
			facts: value.facts,
			links: links,
			bounds: value.bounds,
			asset: value.asset,
			deleted: value.deleted,
			fields: [for (field in raw) (field : String)]
		};
	}

	/** Wire JSON for a node, with one key order on every target. */
	@:allow(hxn.assets.knowledge.KnowledgeBatch)
	static function encode(data:KnowledgeData):String {
		return data.fields == null ? Json.stringify({
			schema: data.schema,
			id: data.id,
			facts: data.facts,
			links: data.links,
			bounds: data.bounds,
			asset: data.asset,
			deleted: data.deleted
		}) : Json.stringify({
			schema: data.schema,
			id: data.id,
			facts: data.facts,
			links: data.links,
			bounds: data.bounds,
			asset: data.asset,
			deleted: data.deleted,
			fields: data.fields
		});
	}

	/**
		`next` applied over `previous` for one entity: a complete snapshot or tombstone replaces it,
		and a partial snapshot overwrites only what it selects. The result is complete when
		`previous` was.
	**/
	@:allow(hxn.assets.knowledge.KnowledgeBatch)
	@:allow(hxn.assets.knowledge.MemoryKnowledgeSink)
	static function merge(previous:KnowledgeData, next:KnowledgeData):KnowledgeData {
		if (next.fields == null || next.deleted)
			return next;
		if (previous.deleted)
			throw "a partial knowledge snapshot needs an earlier complete snapshot of the entity";
		final facts:Dynamic = {};
		for (name in Reflect.fields(previous.facts))
			Reflect.setField(facts, name, Reflect.field(previous.facts, name));
		for (name in Reflect.fields(next.facts))
			Reflect.setField(facts, name, Reflect.field(next.facts, name));
		final relations = previous.schema.relations;
		final links = [
			for (index in 0...relations.length)
				(next.fields.indexOf(relations[index].name) >= 0 ? next.links[index] : previous.links[index]).copy()
		];
		final spatial = previous.schema.spatial;
		final moved = spatial != null && next.fields.indexOf(spatial.relation) >= 0;
		final merged:KnowledgeData = {
			schema: previous.schema,
			id: previous.id,
			facts: facts,
			links: links,
			bounds: moved ? next.bounds : previous.bounds,
			asset: next.asset != null ? next.asset : previous.asset,
			deleted: false
		};
		if (previous.fields == null)
			return merged;
		final fields = previous.fields.copy();
		for (field in next.fields)
			if (fields.indexOf(field) < 0)
				fields.push(field);
		fields.sort(Reflect.compare);
		return owned(Json.parse(encode({
			schema: merged.schema,
			id: merged.id,
			facts: merged.facts,
			links: merged.links,
			bounds: merged.bounds,
			asset: merged.asset,
			deleted: false,
			fields: fields
		})));
	}

	/** Whether the snapshot carries only some of its schema's facts and relationships. */
	public function isPartial():Bool
		return data().fields != null;

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

	/** The selected fact and relationship names of a partial snapshot; absent when complete. */
	@:optional var fields:Array<String>;
}

/** Source identity only; transport URIs, headers and credentials are excluded. */
typedef KnowledgeAssetOrigin = {
	var address:String;
	@:optional var contentId:String;
}
