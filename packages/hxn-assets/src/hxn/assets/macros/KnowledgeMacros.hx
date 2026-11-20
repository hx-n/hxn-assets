package hxn.assets.macros;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/** Generates selected-field reads from class/typedef metadata without runtime reflection. */
class KnowledgeMacros {
	public static function capture(value:Expr, deleted:Bool, ?selection:Expr):Expr {
		final typed = Context.typeExpr(value), type = typed.t;
		final model = declaration(type, value.pos);
		final fields = model.fields.copy();
		fields.sort((a, b) -> Reflect.compare(a.name, b.name));
		// A partial capture reads the identity and the selected fields; the schema stays complete.
		var chosen:Null<Array<String>> = null;
		if (selection != null) {
			chosen = [];
			switch (selection.expr) {
				case EArrayDecl(values):
					for (entry in values) {
						final name = literal(entry);
						if (chosen.indexOf(name) >= 0)
							Context.error('captureFields names $name twice', entry.pos);
						chosen.push(name);
					}
				case _:
					Context.error("captureFields expects an array literal of field names", selection.pos);
			}
			if (chosen.length == 0)
				Context.error("captureFields selects at least one field", selection.pos);
			final declared = [for (field in fields) field.name => field];
			for (name in chosen) {
				final field = declared.get(name);
				if (field == null)
					Context.error('captureFields: ${model.name} has no field $name', selection.pos);
				if (single(field.meta.get(), ":identity") != null)
					Context.error("captureFields always reads the identity; name only facts, relations and spatial fields", selection.pos);
				if ([":fact", ":relation", ":spatial"].filter(meta -> single(field.meta.get(), meta) != null).length == 0)
					Context.error('captureFields: $name has no knowledge annotation', selection.pos);
			}
			// The spatial value and the relationship naming its world are selected together.
			for (field in fields) {
				final entry = single(field.meta.get(), ":spatial");
				if (entry == null || entry.params.length < 1)
					continue;
				final world = literal(entry.params[0]);
				if (chosen.indexOf(field.name) >= 0 && chosen.indexOf(world) < 0)
					chosen.push(world);
				if (chosen.indexOf(world) >= 0 && chosen.indexOf(field.name) < 0)
					chosen.push(field.name);
			}
		}
		final picks = (name:String) -> chosen == null || chosen.indexOf(name) >= 0;
		final selectedNames:Array<String> = [];
		final facts:Array<Dynamic> = [], relations:Array<Dynamic> = [];
		final values:Array<ObjectField> = [], links:Array<Expr> = [], reads:Array<Expr> = [];
		final locals = new Map<String, Expr>(), relationFields = new Map<String, Dynamic>();
		var identity:Null<String> = null, spatial:Null<ClassField> = null;
		for (field in fields) {
			final annotations = [
				for (name in [":identity", ":fact", ":relation", ":spatial"])
					if (single(field.meta.get(), name) != null) name
			];
			if (annotations.length == 0)
				continue;
			if (annotations.length > 1)
				Context.error("select one knowledge annotation per field", field.pos);
			final name = annotations[0], entry = single(field.meta.get(), name);
			final local = '__hxnKnowledgeField${[for (key in locals.keys()) key].length}';
			final access:Expr = {expr: EField(macro __hxnKnowledgeValue, field.name), pos: field.pos};
			final reference:Expr = {expr: EConst(CIdent(local)), pos: field.pos};
			locals.set(field.name, reference);
			if ((!deleted && picks(field.name)) || name == ":identity")
				reads.push(macro var $local = $access);
			switch (name) {
				case ":identity":
					noArguments(entry);
					if (identity != null)
						Context.error("knowledge types require exactly one @:identity field", field.pos);
					if (field.meta.has(":optional") || scalar(field.type, field.pos) != "string" || nullable(field.type))
						Context.error("@:identity requires a non-null String", field.pos);
					identity = field.name;
				case ":fact":
					if (entry.params.length > 1)
						Context.error("@:fact expects an optional property name", entry.pos);
					final output = entry.params.length == 0 ? field.name : literal(entry.params[0]);
					validName(output, entry.pos);
					final kind = factKind(field.type, field.pos);
					facts.push({name: output, kind: kind, nullable: nullable(field.type) || field.meta.has(":optional")});
					if (picks(field.name)) {
						values.push({field: output, expr: reference});
						selectedNames.push(output);
					}
				case ":relation":
					if (entry.params.length != 1)
						Context.error("@:relation expects one relationship name", entry.pos);
					final output = literal(entry.params[0]);
					validName(output, entry.pos);
					var target = unnull(field.type), many = false;
					switch (Context.follow(target)) {
						case TInst(cls, parameters) if (cls.get().name == "Array" && cls.get().pack.length == 0):
							many = true;
							target = parameters[0];
						case _:
					}
					if (many && !deleted && picks(field.name))
						reads.push(macro if ($reference != null && $reference.length > 1024) throw "knowledge relationship list exceeds 1024 targets");
					if (many && nullable(target))
						Context.error("knowledge relationship arrays require non-null targets", field.pos);
					final targetType = switch (Context.follow(target)) {
						case TAbstract(cls, parameters) if (cls.get().name == "KnowledgeRef" && cls.get().pack.join(".") == "hxn.assets"):
							parameters[0];
						case _: Context.error("@:relation requires KnowledgeRef<T> or Array<KnowledgeRef<T>>", field.pos);
					};
					final targetModel = declaration(targetType, field.pos);
					final description = {
						name: output,
						target: targetModel.name,
						many: many,
						nullable: nullable(field.type) || field.meta.has(":optional")
					};
					relations.push(description);
					relationFields.set(field.name, description);
					if (!picks(field.name))
						links.push(macro []);
					else {
						selectedNames.push(output);
						links.push(many ? macro($reference == null ? [] : [for (__id in $reference) (cast __id : String)]) : macro($reference == null ? [] : [(cast $reference : String)]));
					}
				case ":spatial":
					if (spatial != null)
						Context.error("only one @:spatial field is supported per knowledge type", field.pos);
					if (entry.params.length < 1 || entry.params.length > 2)
						Context.error("@:spatial expects a world relationship field and optional units", entry.pos);
					spatial = field;
				case _:
			}
		}
		if (identity == null)
			Context.error("knowledge types require exactly one @:identity field", value.pos);
		validName(identity, value.pos);
		final used = [identity];
		for (field in facts.concat(relations)) {
			if (used.indexOf(field.name) >= 0)
				Context.error("duplicate semantic knowledge property or relationship", value.pos);
			used.push(field.name);
		}
		var bounds:Expr = macro null;
		var spatialSelection:Dynamic = null;
		final spatialRead = spatial != null && picks(spatial.name);
		if (spatial != null) {
			final entry = single(spatial.meta.get(), ":spatial");
			final world = literal(entry.params[0]);
			final relation = relationFields.get(world);
			if (relation == null || relation.many || relation.nullable)
				Context.error("@:spatial world must name a required single @:relation field", entry.pos);
			final units = entry.params.length == 2 ? literal(entry.params[1]) : "unit";
			spatialSelection = {relation: relation.name, units: units};
			if (units.length > 64)
				Context.error("spatial units exceed 64 characters", entry.pos);
			final shape = switch (Context.follow(spatial.type)) {
				case TAnonymous(record): record.get().fields;
				case _: Context.error("@:spatial expects a typed point or AABB structure", spatial.pos);
			};
			final components = new Map<String, ClassField>();
			for (field in shape)
				components.set(field.name, field);
			final point = components.exists("x") && components.exists("y");
			final required = point ? ["x", "y"] : ["minX", "minY", "maxX", "maxY"];
			if (point && components.exists("minX"))
				Context.error("spatial values must be a point or an AABB", spatial.pos);
			for (name in required)
				if (!components.exists(name))
					Context.error("@:spatial expects x/y[/z] or minX/minY/maxX/maxY[/minZ/maxZ]", spatial.pos);
			if (!point && components.exists("minZ") != components.exists("maxZ"))
				Context.error("spatial minZ and maxZ must be supplied together", spatial.pos);
			final selected = point ? ["x", "y", "z"] : ["minX", "minY", "minZ", "maxX", "maxY", "maxZ"];
			for (name in selected)
				if (components.exists(name)) {
					final component = components.get(name), kind = scalar(component.type, component.pos);
					if (["int", "float"].indexOf(kind) < 0 || nullable(component.type) || component.meta.has(":optional"))
						Context.error("spatial components must be required finite numbers", component.pos);
				}
			final position = locals.get(spatial.name);
			function component(name:String):Expr
				return components.exists(name) ? {expr: EField(position, name), pos: spatial.pos} : macro 0.0;
			if (spatialRead)
				bounds = macro {
					world: (cast ${locals.get(world)} : String),
					units: $v{units},
					minX: ${component(point ? "x" : "minX")},
					minY: ${component(point ? "y" : "minY")},
					minZ: ${component(point ? "z" : "minZ")},
					maxX: ${component(point ? "x" : "maxX")},
					maxY: ${component(point ? "y" : "maxY")},
					maxZ: ${component(point ? "z" : "maxZ")}
				};
		}
		final schema = Context.makeExpr({
			name: model.name,
			version: model.version,
			identity: identity,
			facts: facts,
			relations: relations,
			spatial: spatialSelection
		}, value.pos);
		final payload:Expr = {expr: EObjectDecl(values), pos: value.pos};
		final asset = deleted ? macro null : assetOrigin(typed);
		final selectedFields:Expr = chosen == null ? macro null : macro $v{selectedNames};
		final result = macro new hxn.assets.knowledge.KnowledgeSnapshot($schema, ${locals.get(identity)}, ${deleted ? macro {} : payload}, ${
			deleted ? macro [] : {
				expr: EArrayDecl(links),
				pos: value.pos
			}
		}, ${deleted ? macro null : bounds}, $asset, $v{deleted}, $selectedFields);
		reads.unshift(macro if (__hxnKnowledgeValue == null) throw "knowledge data must not be null");
		reads.push(macro return $result);
		final body:Expr = {expr: EBlock(reads), pos: value.pos};
		final input = TypeTools.toComplexType(type);
		return macro(function(__hxnKnowledgeValue:$input):hxn.assets.knowledge.KnowledgeSnapshot$body)($value);
	}

	static function declaration(type:Type, pos:Position):{name:String, version:Int, fields:Array<ClassField>} {
		var metadata:Metadata = [];
		var current = type;
		while (true)
			switch (current) {
				case TType(reference, parameters):
					final definition = reference.get();
					if (metadata.length == 0 && definition.meta.has(":knowledge"))
						metadata = definition.meta.get();
					current = TypeTools.applyTypeParameters(definition.type, definition.params, parameters);
				case TLazy(resolve):
					current = resolve();
				case TInst(reference, parameters):
					final definition = reference.get();
					if (metadata.length == 0)
						metadata = definition.meta.get();
					final entry = single(metadata, ":knowledge");
					if (entry == null)
						Context.error("knowledge data requires @:knowledge on its declared class or typedef", pos);
					final fields = definition.fields.get().copy();
					if (definition.superClass != null)
						Context.error("knowledge classes must declare their selected fields directly", pos);
					return describe(entry, fields, pos);
				case TAnonymous(reference):
					final entry = single(metadata, ":knowledge");
					if (entry == null)
						Context.error("knowledge data requires @:knowledge on its declared class or typedef", pos);
					return describe(entry, reference.get().fields, pos);
				case _:
					Context.error("knowledge data requires a declared class or typedef", pos);
			}
	}

	static function describe(entry:MetadataEntry, fields:Array<ClassField>, pos:Position):{name:String, version:Int, fields:Array<ClassField>} {
		if (entry.params.length < 1 || entry.params.length > 2)
			Context.error("@:knowledge expects a semantic type and optional schema version", entry.pos);
		final name = literal(entry.params[0]);
		validName(name, entry.pos);
		final version = entry.params.length == 1 ? 1 : switch (entry.params[1].expr) {
			case EConst(CInt(value, _)): Std.parseInt(value);
			case _: Context.error("knowledge schema version must be a positive integer literal", entry.pos);
		};
		if (version == null || version < 1)
			Context.error("knowledge schema version must be positive", entry.pos);
		if (fields.length > 256)
			Context.error("knowledge types exceed 256 declared fields", pos);
		final identities = [for (field in fields) if (single(field.meta.get(), ":identity") != null) field];
		if (identities.length != 1)
			Context.error("knowledge types require exactly one @:identity field", pos);
		final id = identities[0];
		if (id.meta.has(":optional") || nullable(id.type) || scalar(id.type, id.pos) != "string")
			Context.error("@:identity requires a non-null String", id.pos);
		return {name: name, version: version, fields: fields};
	}

	static function nullable(type:Type):Bool
		return switch (type) {
			case TType(reference, parameters) if (reference.get().name == "Null" && reference.get().pack.length == 0): true;
			case TAbstract(reference, _) if (reference.get().name == "Null" && reference.get().pack.length == 0): true;
			case TType(reference, parameters): nullable(TypeTools.applyTypeParameters(reference.get().type, reference.get().params, parameters));
			case TLazy(resolve): nullable(resolve());
			case _: false;
		};

	static function unnull(type:Type):Type
		return switch (type) {
			case TType(reference, parameters) if (reference.get().name == "Null" && reference.get().pack.length == 0): parameters[0];
			case TAbstract(reference, parameters) if (reference.get().name == "Null" && reference.get().pack.length == 0): parameters[0];
			case TType(reference, parameters): unnull(TypeTools.applyTypeParameters(reference.get().type, reference.get().params, parameters));
			case TLazy(resolve): unnull(resolve());
			case _: type;
		};

	static function scalar(type:Type, pos:Position):String
		return switch (Context.follow(unnull(type))) {
			case TInst(reference, _) if (reference.get().name == "String" && reference.get().pack.length == 0): "string";
			case TAbstract(reference, _) if (reference.get().pack.length == 0):
				switch (reference.get().name) {
					case "Int": "int";
					case "Float": "float";
					case "Bool": "bool";
					case _: "unsupported";
				}
			case _: "unsupported";
		};

	static function factKind(type:Type, pos:Position):String {
		final kind = scalar(type, pos);
		if (kind != "unsupported")
			return kind;
		switch (Context.follow(unnull(type))) {
			case TInst(reference, parameters) if (reference.get().name == "Array" && reference.get().pack.length == 0):
				final child = scalar(parameters[0], pos);
				if (child != "unsupported" && !nullable(parameters[0]))
					return child + "[]";
			case _:
		}
		return Context.error("@:fact requires a scalar or an array of non-null scalars; annotate structured fields individually", pos);
	}

	static function single(metadata:Metadata, name:String):Null<MetadataEntry> {
		final entries = [for (entry in metadata) if (entry.name == name) entry];
		if (entries.length > 1)
			Context.error('duplicate $name metadata', entries[1].pos);
		return entries.length == 0 ? null : entries[0];
	}

	static function literal(value:Expr):String
		return switch (value.expr) {
			case EConst(CString(text, _)) if (text.length > 0): text;
			case _: Context.error("knowledge metadata expects nonempty string literals", value.pos);
		};

	static function validName(name:String, pos:Position):Void {
		if (!~/^[A-Za-z][A-Za-z0-9_]{0,63}$/.match(name))
			Context.error("knowledge names must be portable identifiers of at most 64 characters", pos);
	}

	static function noArguments(entry:MetadataEntry):Void {
		if (entry.params.length != 0)
			Context.error(entry.name + " takes no arguments", entry.pos);
	}

	static function assetOrigin(value:TypedExpr):Expr {
		return switch (value.expr) {
			case TField(_, FStatic(owner, field)): assetField(owner, field.get(), value.pos);
			case TCall(callee, arguments):
				switch (callee.expr) {
					case TField(_, FStatic(owner, getter)) if (arguments.length == 0 && StringTools.startsWith(getter.get().name, "get_")):
						final name = getter.get().name.substr(4);
						final fields = [
							for (field in owner.get().statics.get())
								if (field.name == name && field.meta.has(":dynamicAsset")) field
						];
						fields.length == 1 ? assetField(owner, fields[0], value.pos) : macro null;
					case _: macro null;
				}
			case TParenthesis(inner) | TMeta(_, inner) | TCast(inner, _): assetOrigin(inner);
			case _: macro null;
		};
	}

	static function assetField(owner:Ref<ClassType>, field:ClassField, pos:Position):Expr {
		final metadata = single(owner.get().meta.get(), ":hxnAssetCatalog");
		final asset = single(field.meta.get(), ":asset");
		if (metadata == null || asset == null)
			return macro null;
		final address = asset.params.length == 1 ? field.name : literal(asset.params[0]);
		final catalog:Dynamic = haxe.Json.parse(literal(metadata.params[0]));
		final assets:Array<Dynamic> = catalog.assets;
		final selected = [for (info in assets) if (info.address == address) info];
		return selected.length == 1 ? Context.makeExpr({address: selected[0].address, contentId: selected[0].contentId}, pos) : macro null;
	}
}
#end
