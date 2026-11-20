package hxn.assets.knowledge;

import haxe.Int64;
import haxe.Json;
import haxe.io.Bytes;

/** Owned query rows. Large signed integers remain haxe.Int64 values. */
class KnowledgeQuery {
	/** Column names in row order. */
	public final columns:Array<String>;

	/** Engine type names for the corresponding columns. */
	public final types:Array<String>;

	/** Owned decoded values; wide signed integers use haxe.Int64. */
	public final rows:Array<Array<Dynamic>>;

	function new(columns:Array<String>, types:Array<String>, rows:Array<Array<Dynamic>>) {
		this.columns = columns;
		this.types = types;
		this.rows = rows;
	}

	@:noCompletion
	public static function decode(json:String):KnowledgeQuery {
		final raw:Dynamic = Json.parse(json);
		final columns:Array<String> = [];
		final types:Array<String> = [];
		final rows:Array<Array<Dynamic>> = [];
		for (i in 0...raw.columns.length)
			columns.push(raw.columns[i]);
		for (i in 0...raw.types.length)
			types.push(raw.types[i]);
		for (i in 0...raw.rows.length) {
			final row:Array<Dynamic> = [];
			for (j in 0...raw.rows[i].length)
				row.push(value(raw.rows[i][j]));
			rows.push(row);
		}
		return new KnowledgeQuery(columns, types, rows);
	}

	@:noCompletion
	public static function encodeParameters(parameters:haxe.DynamicAccess<Dynamic>):String {
		final object:Dynamic = {};
		final names = Reflect.fields(parameters);
		if (names.length > 64)
			throw "too many graph query parameters";
		final budget = {used: 0};
		for (name in names) {
			if (name.length > 256)
				throw "graph parameter name exceeds its limit";
			budget.used += 3 * name.length;
			Reflect.setField(object, name, parameter(Reflect.field(parameters, name), budget, 0));
		}
		final encoded = Json.stringify(object);
		if (Bytes.ofString(encoded).length > 262144)
			throw "graph parameters exceed 256 KiB";
		return encoded;
	}

	static function tag(kind:String, data:Dynamic):Array<Dynamic>
		return [kind, data];

	static function parameter(data:Dynamic, budget:{used:Int}, depth:Int):Array<Dynamic> {
		budget.used += 32;
		if (depth > 32 || budget.used > 262144)
			throw "graph parameter structure exceeds its limit";
		if (data == null)
			return tag("null", null);
		if (Int64.isInt64(data))
			return tag("int64", Int64.toStr(data));
		if (Std.isOfType(data, Bytes)) {
			final bytes:Bytes = cast data;
			if (bytes.length > 65536)
				throw "graph parameter blob exceeds 64 KiB";
			budget.used += bytes.length * 2;
			return tag("blob", bytes.toHex());
		}
		if (Std.isOfType(data, Array)) {
			final items:Array<Dynamic> = cast data;
			if (items.length > 1024)
				throw "graph parameter list exceeds its limit";
			final encoded:Array<Dynamic> = [];
			for (item in items)
				encoded.push(parameter(item, budget, depth + 1));
			return tag("list", encoded);
		}
		return switch (Type.typeof(data)) {
			case TBool: tag("bool", data);
			case TInt: tag("int", data);
			case TFloat:
				if (!Math.isFinite(data))
					throw "graph parameter is not finite";
				tag("float", data);
			case TClass(c) if (c == String):
				final text:String = data;
				if (text.length > 65536)
					throw "graph parameter string exceeds its limit";
				budget.used += 3 * text.length;
				tag("string", text);
			case TObject:
				final names = Reflect.fields(data);
				if (names.length > 64)
					throw "graph parameter object exceeds its limit";
				final fields:Dynamic = {};
				for (name in names) {
					if (name.length > 256)
						throw "graph parameter field name exceeds its limit";
					budget.used += 3 * name.length;
					Reflect.setField(fields, name, parameter(Reflect.field(data, name), budget, depth + 1));
				}
				tag("object", fields);
			case _: throw "unsupported graph query parameter type";
		};
	}

	static function value(raw:Dynamic):Dynamic {
		final kind:String = raw[0];
		final data:Dynamic = raw[1];
		switch (kind) {
			case "null":
				return null;
			case "bool", "int", "float", "string", "integer", "value":
				return data;
			case "int64":
				final wide = Int64.parseString(data);
				if ((wide.high == 0 && wide.low >= 0) || (wide.high == -1 && wide.low < 0))
					return wide.low;
				return wide;
			case "blob":
				return Bytes.ofHex(data);
			case "list":
				final items:Array<Dynamic> = [];
				for (i in 0...data.length)
					items.push(value(data[i]));
				return items;
			case "object":
				final object:Dynamic = {};
				for (name in Reflect.fields(data))
					Reflect.setField(object, name, value(Reflect.field(data, name)));
				return object;
			case "map":
				final pairs:Array<{key:Dynamic, value:Dynamic}> = [];
				for (i in 0...data.length)
					pairs.push({key: value(data[i][0]), value: value(data[i][1])});
				return pairs;
			case _:
				throw "unknown graph result kind";
		}
	}
}
