package hxn.assets.macros;

#if macro
import haxe.io.Bytes;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import hxn.assets.AssetDecode;

/** Compile-time payload selection and expected-type descriptions. */
class Values {
	public static function kind(type:Null<ComplexType>, path:String, explicit:Null<String>, pos:Position, dynamicAsset:Bool):String {
		if (explicit != null) {
			if (["json", "text", "binary", "png", "xml", "haxe"].indexOf(explicit) < 0)
				Context.error('unsupported asset format $explicit', pos);
			return explicit;
		}
		if (type != null) {
			final resolved = Context.follow(Context.resolveType(type, pos));
			switch (resolved) {
				case TInst(reference, _):
					final name = reference.get().pack.concat([reference.get().name]).join(".");
					if (name == "String")
						return "text";
					if (name == "haxe.io.Bytes")
						return "binary";
					if (name == "hxn.assets.ImageData")
						return "png";
					if (name == "Xml")
						return "xml";
					if (name == "Array")
						return "json";
				case TAnonymous(_):
					return "json";
				case TAbstract(reference, _):
					if (["Int", "Float", "Bool", "Null"].indexOf(reference.get().name) >= 0)
						return "json";
				case TDynamic(_):
					if (dynamicAsset)
						return "binary";
				case _:
			}
		}
		final extension = haxe.io.Path.extension(path).toLowerCase();
		return switch (extension) {
			case "json": "json";
			case "txt" | "text" | "csv" | "glsl" | "wgsl" | "hxsl": "text";
			case "bin" | "dat": "binary";
			case "png": "png";
			case "xml": "xml";
			case "hxs" | "hxser": "haxe";
			case _: Context.error("cannot infer this asset's data; declare its expected type or mark @:dynamicAsset for application decoding", pos);
		};
	}

	public static function defaultType(kind:String):ComplexType {
		return switch (kind) {
			case "text": macro :String;
			case "binary": macro :haxe.io.Bytes;
			case "png": macro :hxn.assets.ImageData;
			case "xml": macro :Xml;
			case _: macro :Dynamic;
		};
	}

	public static function embed(bytes:Bytes, kind:String, name:String, pos:Position):Expr {
		try {
			return switch (kind) {
				case "text": Context.makeExpr(bytes.toString(), pos);
				case "json": Context.makeExpr(haxe.Json.parse(bytes.toString()), pos);
				case "haxe": Context.makeExpr(haxe.Unserializer.run(bytes.toString()), pos);
				case "xml":
					Xml.parse(bytes.toString());
					macro Xml.parse($v{bytes.toString()});
				case "binary": resource(bytes, name);
				case "png":
					final image = AssetDecode.png(bytes), pixels = resource(image.pixels, name);
					macro new hxn.assets.ImageData($v{image.width}, $v{image.height}, $pixels);
				case _: Context.error('unsupported embedded asset format $kind', pos);
			};
		} catch (error:Dynamic) {
			Context.error('cannot decode embedded asset: ${Std.string(error)}; use @:dynamicAsset with a runtime decoder for unsupported values', pos);
			return macro null;
		}
	}

	static function resource(bytes:Bytes, name:String):Expr {
		Context.addResource(name, bytes);
		return macro haxe.Resource.getBytes($v{name});
	}

	public static function decode(bytes:Expr, kind:String, type:ComplexType, pos:Position):Expr {
		return switch (kind) {
			case "text": macro $bytes.toString();
			case "binary": bytes;
			case "png": macro hxn.assets.AssetDecode.png($bytes);
			case "xml": macro Xml.parse($bytes.toString());
			case "json":
				final expected = Context.makeExpr(shape(Context.resolveType(type, pos), pos, []), pos);
				macro hxn.assets.AssetDecode.json($bytes, $expected);
			case "haxe":
				Context.error("dynamic Haxe serialization needs @:assetDecode with an application decoder", pos);
			case _: Context.error('unsupported dynamic asset format $kind', pos);
		};
	}

	static function shape(type:Type, pos:Position, visited:Array<String>):Dynamic {
		return switch (type) {
			case TMono(reference): reference.get() == null ? {kind: "any"} : shape(reference.get(), pos, visited);
			case TLazy(resolve): shape(resolve(), pos, visited);
			case TDynamic(_): {kind: "any"};
			case TType(reference, parameters):
				final name = reference.get().module + "." + reference.get().name;
				if (visited.indexOf(name) >= 0)
					Context.error("recursive dynamic asset types need @:assetDecode", pos);
				shape(haxe.macro.TypeTools.applyTypeParameters(reference.get().type, reference.get().params, parameters), pos, visited.concat([name]));
			case TAbstract(reference, parameters):
				final name = reference.get().name;
				switch (name) {
					case "Int": {kind: "int"};
					case "Float": {kind: "float"};
					case "Bool": {kind: "bool"};
					case "Null": {kind: "nullable", value: shape(parameters[0], pos, visited)};
					case _: Context.error("this dynamic asset type needs @:assetDecode", pos);
				}
			case TInst(reference, parameters):
				switch (reference.get().name) {
					case "String": {kind: "string"};
					case "Array": {kind: "array", value: shape(parameters[0], pos, visited)};
					case _: Context.error("class-valued dynamic assets need @:assetDecode", pos);
				}
			case TAnonymous(reference):
				{
					kind: "object",
					fields: [
						for (field in reference.get().fields)
							{name: field.name, optional: field.meta.has(":optional"), value: shape(field.type, pos, visited)}
					]
				};
			case _: Context.error("this dynamic asset type needs @:assetDecode", pos);
		};
	}
}
#end
