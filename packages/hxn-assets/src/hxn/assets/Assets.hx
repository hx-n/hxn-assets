package hxn.assets;

#if macro
import haxe.crypto.Sha256;
import haxe.io.Path;
import haxe.macro.Context;
import haxe.macro.Expr;
import sys.FileSystem;
import sys.io.File;
import hxn.assets.macros.Values;
#end

/**
 * Generates typed asset values, catalogs and provider addresses from metadata.
 *
 * ```haxe
 * @:build(hxn.assets.Assets.build())
 * class GameAssets {
 *     @:asset("levels/start.json")
 *     @:contentAddressed
 *     public static var Start:{name:String, lives:Int};
 * }
 * ```
 *
 * `GameAssets.Start` is decoded embedded data. String fields contain text;
 * Bytes fields contain binary payloads; ImageData contains PNG pixels.
 * Mark runtime-only data with `@:dynamicAsset`, then await `load(loader)` before
 * reading it. Declared types select decoding; untyped dynamic values are bytes
 * for application decoding. `@:assetDecode(fn)` supplies a custom runtime decoder.
 * Provider addresses are generated under `GameAssets.addresses`; `catalog()`
 * returns descriptors. `@:assetDependsOn(OtherField)` declares dependencies.
 */
class Assets {
	/** Generates embedded values, dynamic loaders, addresses and a catalog factory. */
	public static macro function build():Array<Field> {
		final fields = Context.getBuildFields(), owner = Context.getLocalClass().get();
		final rootValue = Context.definedValue("hxn_assets_dir");
		final directory = rootValue == null ? "assets" : rootValue;
		final classHash = hashing(owner.meta.get());
		final declarations:Array<Declaration> = [];
		final byField = new Map<String, String>();
		for (field in fields) {
			if (StringTools.startsWith(field.name, "__hxn_"))
				Context.error("__hxn_ field names are reserved for asset generation", field.pos);
			final metadata = field.meta == null ? [] : field.meta;
			final entry = single(metadata, ":asset");
			if (entry == null) {
				for (name in [
					":contentAddressed",
					":assetGroup",
					":assetLabels",
					":assetDependsOn",
					":assetMediaType",
					":dynamicAsset",
					":assetFormat",
					":assetDecode"
				])
					if (single(metadata, name) != null)
						Context.error('$name requires an @:asset field', field.pos);
				continue;
			}
			if (["catalog", "addresses", "load", "unload"].indexOf(field.name) >= 0)
				Context.error("field name is reserved for generated asset helpers", field.pos);
			if (field.access == null || field.access.indexOf(AStatic) < 0)
				Context.error("@:asset requires a static field", field.pos);
			switch (field.kind) {
				case FVar(type, value):
					if (value != null)
						Context.error("@:asset fields must not have an initializer", value.pos);
				case _:
					Context.error("@:asset requires a static variable", field.pos);
			}
			if (entry.params.length < 1 || entry.params.length > 2)
				Context.error("@:asset expects a path, or an address and path", entry.pos);
			final address = entry.params.length == 1 ? field.name : literal(entry.params[0]);
			final rawPath = literal(entry.params[entry.params.length - 1]);
			final remote = RemoteUri.isUri(rawPath);
			var path:String;
			try {
				path = remote ? RemoteUri.normalize(rawPath) : rawPath;
			} catch (error:Dynamic) {
				Context.error(Std.string(error), entry.pos);
				return fields;
			}
			final dynamicEntry = single(metadata, ":dynamicAsset"), decodeEntry = single(metadata, ":assetDecode");
			final dynamicAsset = dynamicEntry != null;
			if (dynamicEntry != null && dynamicEntry.params.length != 0)
				Context.error("@:dynamicAsset takes no arguments", dynamicEntry.pos);
			if (decodeEntry != null && (!dynamicAsset || decodeEntry.params.length != 1))
				Context.error("@:assetDecode requires @:dynamicAsset and one decoder function", decodeEntry.pos);
			var expected:Null<ComplexType> = switch (field.kind) {
				case FVar(type, _): type;
				case _: null;
			};
			if (remote && !dynamicAsset)
				Context.error("remote URI assets require @:dynamicAsset; compilation does not fetch network content", field.pos);
			var payload:Null<ComplexType> = null;
			if (expected != null)
				switch (Context.follow(Context.resolveType(expected, field.pos))) {
					case TInst(reference, parameters) if (reference.get().pack.join(".") == "hxn.assets"
						&& reference.get().name == "AssetStream"):
						payload = haxe.macro.TypeTools.toComplexType(parameters[0]);
					case _:
				}
			if (remote && RemoteUri.socket(path) && payload == null && expected == null) {
				payload = macro :haxe.io.Bytes;
				expected = macro :hxn.assets.AssetStream<haxe.io.Bytes>;
			}
			final streaming = payload != null;
			if (streaming && !dynamicAsset)
				Context.error("stream assets require @:dynamicAsset", field.pos);
			if (remote && RemoteUri.socket(path) && !streaming)
				Context.error("WS(S) assets require AssetStream<T>", field.pos);
			final format = single(metadata, ":assetFormat");
			if (format != null && decodeEntry != null)
				Context.error("select either @:assetFormat or @:assetDecode", format.pos);
			final target = streaming ? payload : expected;
			final kind = decodeEntry != null ? "custom" : dynamicAsset
				&& target == null
				&& format == null ? "binary" : Values.kind(target, path, format == null ? null : argument(format), field.pos, dynamicAsset);
			if (expected == null)
				expected = Values.defaultType(kind);
			if (payload == null)
				payload = expected;
			if (streaming && remote && !RemoteUri.socket(path) && kind != "binary" && decodeEntry == null)
				Context.error("HTTP streams are byte chunks; use AssetStream<Bytes> or an explicit framing decoder", field.pos);
			var file:Null<String> = null;
			try {
				if (!remote)
					Build.relativePath(path);
				if (!remote && (!dynamicAsset || FileSystem.exists(Path.join([directory, path]))))
					file = Build.sourceFile(directory, path);
			} catch (error:Dynamic) {
				Context.error(Std.string(error), entry.pos);
				return fields;
			}
			if (file != null) {
				Context.registerModuleDependency(owner.module, file);
				Context.registerModuleDependency(owner.module, FileSystem.absolutePath(Path.join([directory, path])));
			}
			final info:AssetInfo = {
				address: address,
				path: path,
				dynamicAsset: dynamicAsset,
				streamAsset: streaming,
				labels: [],
				dependencies: []
			};
			final fieldHash = hashing(metadata);
			if (classHash || fieldHash) {
				if (streaming)
					Context.error("an unbounded stream has no whole-content digest", field.pos);
				if (file == null)
					Context.error("content addressing requires known source bytes at compilation", field.pos);
				info.contentId = "sha256:" + Sha256.make(File.getBytes(file)).toHex();
			}
			final group = single(metadata, ":assetGroup"), mediaType = single(metadata, ":assetMediaType");
			if (group != null)
				info.group = argument(group);
			if (mediaType != null)
				info.mediaType = argument(mediaType);
			final labels = single(metadata, ":assetLabels"), dependencies = single(metadata, ":assetDependsOn");
			if (labels != null)
				info.labels = [for (value in labels.params) literal(value)];
			declarations.push({
				field: field,
				info: info,
				dependencies: dependencies == null ? [] : dependencies.params,
				expected: expected,
				payload: payload,
				kind: kind,
				value: dynamicAsset ? null : Values.embed(File.getBytes(file), kind, owner.module + "." + owner.name + "." + field.name, field.pos),
				decoder: decodeEntry == null ? null : decodeEntry.params[0]
			});
			byField.set(field.name, address);
		}
		if (declarations.length == 0)
			Context.error("asset declarations must contain at least one @:asset field", Context.currentPos());
		for (field in fields)
			if (["catalog", "addresses", "load", "unload"].indexOf(field.name) >= 0)
				Context.error("field name is reserved for generated asset helpers", field.pos);
		for (declaration in declarations) {
			for (dependency in declaration.dependencies) {
				final name = switch (dependency.expr) {
					case EConst(CIdent(name)): name;
					case _: Context.error("@:assetDependsOn expects asset field names from this class", dependency.pos);
				};
				if (!byField.exists(name))
					Context.error('unknown asset field $name', dependency.pos);
				declaration.info.dependencies.push(byField.get(name));
			}
		}
		var catalog:AssetCatalog;
		try {
			catalog = new AssetCatalog([for (declaration in declarations) declaration.info]);
		} catch (error:Dynamic) {
			Context.error(Std.string(error), Context.currentPos());
			return fields;
		}
		final json = catalog.toJson();
		final addressFields:Array<Field> = [], addressValues:Array<ObjectField> = [];
		for (declaration in declarations) {
			final field = declaration.field;
			field.access = [for (access in field.access) if (access != AFinal && access != AInline) access];
			addressFields.push({
				name: field.name,
				access: [AFinal],
				kind: FVar(macro :String),
				pos: field.pos
			});
			addressValues.push({field: field.name, expr: macro $v{declaration.info.address}});
			if (!declaration.info.dynamicAsset)
				field.kind = FProp("default", "never", declaration.expected, declaration.value);
		}
		fields.push({
			name: "addresses",
			access: [APublic, AStatic, AFinal],
			kind: FVar(TAnonymous(addressFields), {expr: EObjectDecl(addressValues), pos: Context.currentPos()}),
			pos: Context.currentPos(),
			doc: "Logical addresses for provider-based loading; annotated fields contain the asset values."
		});
		generateDynamic(fields, [for (declaration in declarations) if (declaration.info.dynamicAsset) declaration]);
		fields.push({
			name: "catalog",
			access: [APublic, AStatic],
			doc: "Returns a fresh catalog generated from this class's asset declarations.",
			pos: Context.currentPos(),
			kind: FFun({
				args: [],
				ret: macro :hxn.assets.AssetCatalog,
				expr: macro return hxn.assets.AssetCatalog.fromJson($v{json})
			})
		});
		// Typed class metadata survives compilation-server module reuse; no static registry.
		owner.meta.remove(":hxnAssetCatalog");
		owner.meta.add(":hxnAssetCatalog", [macro $v{json}], Context.currentPos());
		return fields;
	}

	#if macro
	static function generateDynamic(fields:Array<Field>, declarations:Array<Declaration>):Void {
		if (declarations.length == 0)
			return;
		final pos = Context.currentPos();
		fields.push({
			name: "__hxn_loaded",
			access: [APrivate, AStatic],
			kind: FVar(macro :Bool, macro false),
			pos: pos
		});
		fields.push({
			name: "__hxn_generation",
			access: [APrivate, AStatic],
			kind: FVar(macro :Int, macro 0),
			pos: pos
		});
		final work:Array<Expr> = [
			(macro final generation = ++__hxn_generation),
			(macro __hxn_loaded = false),
			(macro var pending:hxn.Future<Array<Dynamic>> = hxn.Future.resolved([])),
			(macro var opened:Array<hxn.assets.AssetStream<Dynamic>> = [])
		];
		final commit:Array<Expr> = [
			macro if (generation != __hxn_generation) throw new haxe.Exception("asset load was superseded")
		];
		final unload:Array<Expr> = [macro __hxn_generation++, macro __hxn_loaded = false];
		for (i in 0...declarations.length) {
			final declaration = declarations[i], field = declaration.field, name = "__hxn_asset_" + field.name, getter = "get_" + field.name;
			for (existing in fields)
				if (existing.name == getter)
					Context.error('generated getter $getter conflicts with an existing field', existing.pos);
			field.kind = FProp("get", "never", declaration.expected);
			fields.push({
				name: name,
				access: [APrivate, AStatic],
				kind: FVar(declaration.expected),
				pos: field.pos
			});
			fields.push({
				name: getter,
				access: [APrivate, AStatic],
				kind: FFun({
					args: [],
					ret: declaration.expected,
					expr: macro {
						if (!__hxn_loaded)
							throw $v{'dynamic asset ' + field.name + ' is not loaded; await load(loader)'};
						return $i{name};
					}
				}),
				pos: field.pos
			});
			final decode = declaration.decoder == null ? Values.decode(macro bytes, declaration.kind, declaration.payload,
				field.pos) : {expr: ECall(declaration.decoder, [macro bytes]), pos: field.pos};
			if (declaration.info.streamAsset) {
				final decoder:Expr = {
					expr: EFunction(FAnonymous, {args: [{name: "bytes", type: macro :haxe.io.Bytes}], ret: declaration.payload, expr: macro return $decode}),
					pos: field.pos
				};
				work.insert(2, macro if ($i{name} != null) $i{name}.close());
				work.push(macro pending = pending.flatMap(values -> loader.openStream($v{declaration.info.address}).map(raw -> {
					final stream = raw.map($decoder);
					opened.push(cast stream);
					values.push(stream);
					return values;
				})));
				unload.push(macro if ($i{name} != null) $i{name}.close());
			} else {
				final decoded:Expr = {expr: EVars([{name: "decoded", type: declaration.expected, expr: decode}]), pos: field.pos};
				work.push(macro pending = pending.flatMap(values -> loader.load($v{declaration.info.address}).map(bytes -> {
					$decoded;
					values.push(decoded);
					return values;
				})));
			}
			commit.push(macro $i{name} = cast values[$v{i}]);
			unload.push(macro $i{name} = cast null);
		}
		commit.push(macro __hxn_loaded = true);
		commit.push(macro return hxn.Unit.Nothing);
		final finished:Expr = {expr: EBlock(commit), pos: pos};
		work.push(macro return pending.map(values -> $finished).recover(error -> {
			for (stream in opened)
				stream.close();
			throw error;
		}));
		fields.push({
			name: "load",
			access: [APublic, AStatic],
			pos: pos,
			doc: "Loads and decodes dynamic fields asynchronously, publishing them together after success.",
			kind: FFun({
				args: [{name: "loader", type: macro :hxn.assets.AssetLoader}],
				ret: macro :hxn.Future<hxn.Unit>,
				expr: {expr: EBlock(work), pos: pos}
			})
		});
		fields.push({
			name: "unload",
			access: [APublic, AStatic],
			pos: pos,
			doc: "Releases dynamic field values and supersedes pending loads; embedded values remain available.",
			kind: FFun({
				args: [],
				ret: macro :Void,
				expr: {expr: EBlock(unload), pos: pos}
			})
		});
	}

	static function single(metadata:Metadata, name:String):Null<MetadataEntry> {
		final entries = [for (entry in metadata) if (entry.name == name) entry];
		if (entries.length > 1)
			Context.error('duplicate $name metadata', entries[1].pos);
		return entries.length == 0 ? null : entries[0];
	}

	static function literal(value:Expr):String {
		return switch (value.expr) {
			case EConst(CString(text, _)) if (text.length > 0 && text.indexOf("\x00") < 0): text;
			case _: Context.error("asset metadata expects nonempty string literals", value.pos);
		};
	}

	static function argument(entry:MetadataEntry):String {
		if (entry.params.length != 1)
			Context.error('${entry.name} expects one string', entry.pos);
		return literal(entry.params[0]);
	}

	static function hashing(metadata:Metadata):Bool {
		final entry = single(metadata, ":contentAddressed");
		if (entry == null)
			return false;
		if (entry.params.length > 1 || (entry.params.length == 1 && literal(entry.params[0]) != "sha256"))
			Context.error("@:contentAddressed supports only sha256", entry.pos);
		return true;
	}
	#end
}

#if macro
private typedef Declaration = {
	var field:Field;
	var info:AssetInfo;
	var dependencies:Array<Expr>;
	var expected:ComplexType;
	var payload:ComplexType;
	var kind:String;
	var value:Null<Expr>;
	var decoder:Null<Expr>;
}
#end
