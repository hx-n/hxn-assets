package hxn.assets;

import haxe.Json;
import haxe.ds.StringMap;

/** An immutable, validated snapshot of addresses, labels, groups and dependencies. */
class AssetCatalog {
	final entries = new StringMap<AssetInfo>();
	final names:Array<String>;

	public function new(assets:Array<AssetInfo>) {
		if (assets == null)
			throw "asset catalog must contain an array";
		for (asset in assets) {
			if (asset == null || !text(asset.address) || !text(asset.path))
				throw "asset address and path must be nonempty text";
			if (entries.exists(asset.address))
				throw 'duplicate asset address: ${asset.address}';
			if (asset.contentId != null && (!Std.isOfType(asset.contentId, String) || !~/^sha256:[0-9a-f]{64}$/.match(asset.contentId)))
				throw 'invalid content ID: ${asset.address}';
			if ((asset.labels != null && !Std.isOfType(asset.labels, Array))
				|| (asset.dependencies != null && !Std.isOfType(asset.dependencies, Array)))
				throw "catalog labels/dependencies must be arrays";
			if ((asset.group != null && !Std.isOfType(asset.group, String))
				|| (asset.mediaType != null && !Std.isOfType(asset.mediaType, String)))
				throw "catalog group/media type must be strings";
			if (asset.dynamicAsset != null && !Std.isOfType(asset.dynamicAsset, Bool))
				throw "catalog dynamicAsset must be a boolean";
			if (asset.streamAsset != null && !Std.isOfType(asset.streamAsset, Bool))
				throw "catalog streamAsset must be a boolean";
			final labels = strings(asset.labels), dependencies = strings(asset.dependencies);
			entries.set(asset.address, {
				address: asset.address,
				path: asset.path,
				contentId: asset.contentId,
				dynamicAsset: asset.dynamicAsset == true,
				streamAsset: asset.streamAsset == true,
				mediaType: asset.mediaType,
				group: asset.group,
				labels: labels,
				dependencies: dependencies
			});
		}
		names = [for (name in entries.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			for (dependency in entries.get(name).dependencies)
				if (!entries.exists(dependency))
					throw 'unknown dependency $dependency of $name';
		final colors = new StringMap<Int>();
		for (name in names)
			visit(name, colors, null);
	}

	static function text(value:Dynamic):Bool {
		if (!Std.isOfType(value, String))
			return false;
		final text:String = value;
		return text.length > 0 && text.indexOf("\x00") < 0;
	}

	static function strings(values:Array<String>):Array<String> {
		if (values == null)
			return [];
		final result:Array<String> = [];
		for (value in values) {
			if (!text(value))
				throw "catalog labels and dependencies must be nonempty strings";
			if (result.indexOf(value) < 0)
				result.push(value);
		}
		result.sort(Reflect.compare);
		return result;
	}

	static function copy(asset:AssetInfo):AssetInfo
		return {
			address: asset.address,
			path: asset.path,
			contentId: asset.contentId,
			dynamicAsset: asset.dynamicAsset == true,
			streamAsset: asset.streamAsset == true,
			mediaType: asset.mediaType,
			group: asset.group,
			labels: asset.labels.copy(),
			dependencies: asset.dependencies.copy()
		};

	function visit(root:String, colors:StringMap<Int>, output:Null<Array<AssetInfo>>):Void {
		if (colors.get(root) == 2)
			return;
		final stack:Array<{name:String, leave:Bool}> = [{name: root, leave: false}];
		while (stack.length > 0) {
			final step = stack.pop();
			if (step.leave) {
				colors.set(step.name, 2);
				if (output != null)
					output.push(copy(entries.get(step.name)));
				continue;
			}
			final color = colors.get(step.name);
			if (color == 2)
				continue;
			if (color == 1)
				throw 'asset dependency cycle at ${step.name}';
			colors.set(step.name, 1);
			stack.push({name: step.name, leave: true});
			final dependencies = entries.get(step.name).dependencies;
			for (i in 0...dependencies.length)
				stack.push({name: dependencies[dependencies.length - 1 - i], leave: false});
		}
	}

	public function get(address:String):AssetInfo {
		final asset = entries.get(address);
		if (asset == null)
			throw 'unknown asset: $address';
		return copy(asset);
	}

	public function all():Array<AssetInfo>
		return [for (name in names) copy(entries.get(name))];

	public function group(name:String):Array<AssetInfo>
		return [for (asset in all()) if (asset.group == name) asset];

	public function labels(required:Array<String>):Array<AssetInfo> {
		final result:Array<AssetInfo> = [];
		for (asset in all()) {
			var found = true;
			for (label in required)
				if (asset.labels.indexOf(label) < 0)
					found = false;
			if (found)
				result.push(asset);
		}
		return result;
	}

	/** Dependencies first, with each address present once and the requested asset last. */
	public function order(address:String):Array<AssetInfo> {
		get(address);
		final result:Array<AssetInfo> = [];
		visit(address, new StringMap<Int>(), result);
		return result;
	}

	public function toJson():String
		return Json.stringify({version: 1, assets: all()});

	public static function fromJson(text:String):AssetCatalog {
		final value:Dynamic = Json.parse(text);
		if (value == null || value.version != 1 || !Std.isOfType(value.assets, Array))
			throw "unsupported asset catalog schema";
		return new AssetCatalog(cast value.assets);
	}
}
