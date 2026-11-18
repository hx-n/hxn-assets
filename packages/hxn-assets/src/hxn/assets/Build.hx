package hxn.assets;

import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
#if macro
import haxe.macro.Context;
import haxe.macro.Compiler;
#end

/** Catalog/staging implementation shared by compiler integration and the installed CLI. */
class Build {
	public static function catalog(directory:String, contentAddressed:Bool = false):Dynamic {
		final base = FileSystem.fullPath(directory);
		if (!FileSystem.isDirectory(base))
			throw "asset source is not a directory";
		final assets:Array<Dynamic> = [], names = new Map<String, Bool>();
		function walk(path:String, relative:String, ancestors:Array<String>):Void {
			final canonical = FileSystem.fullPath(path);
			if (canonical != base && !StringTools.startsWith(canonical, base + "/"))
				throw "asset symlink escapes its source directory";
			if (ancestors.indexOf(canonical) >= 0)
				throw "asset directory cycle";
			final next = ancestors.concat([canonical]);
			final entries = FileSystem.readDirectory(path);
			entries.sort(Reflect.compare);
			for (name in entries) {
				final source = Path.join([path, name]), key = relative == "" ? name : relative + "/" + name;
				final resolved = FileSystem.fullPath(source);
				if (resolved != base && !StringTools.startsWith(resolved, base + "/"))
					throw "asset symlink escapes its source directory";
				if (FileSystem.isDirectory(source))
					walk(source, key, next);
				else {
					if (key == ".hxn-assets.json")
						throw "asset source uses reserved catalog name .hxn-assets.json";
					final folded = key.toLowerCase();
					if (names.exists(folded))
						throw 'asset paths collide on case-insensitive platforms: $key';
					names.set(folded, true);
					final info:Dynamic = {
						address: key,
						path: key,
						labels: [],
						dependencies: []
					};
					if (contentAddressed)
						info.contentId = "sha256:" + Sha256.make(File.getBytes(source)).toHex();
					assets.push(info);
				}
			}
		}
		walk(base, "", []);
		return {version: 1, assets: assets};
	}

	public static function stage(directory:String, output:String, contentAddressed:Bool = false):Void {
		final source = FileSystem.fullPath(directory), destination = FileSystem.absolutePath(output);
		if (destination == source || StringTools.startsWith(destination, source + "/"))
			throw "asset output must be outside its source directory";
		final manifest = catalog(source, contentAddressed);
		FileSystem.createDirectory(destination);
		for (asset in (manifest.assets : Array<Dynamic>)) {
			final into = Path.join([destination, asset.path]);
			FileSystem.createDirectory(Path.directory(into));
			File.copy(Path.join([source, asset.path]), into);
		}
		File.saveContent(Path.join([destination, ".hxn-assets.json"]), Json.stringify(manifest));
	}

	#if macro
	public static macro function register():haxe.macro.Expr {
		Compiler.define("hxn_assets_managed");
		final value = Context.definedValue("hxn_assets_dir"), source = value == null ? "assets" : value;
		final addressed = Context.defined("hxn_assets_content_addressed");
		Context.onAfterGenerate(() -> {
			if (!FileSystem.exists(source))
				return;
			final output = FileSystem.absolutePath(Compiler.getOutput());
			final directory = Context.defined("cpp") && !Context.defined("cppia") ? output : Path.directory(output);
			stage(source, Path.join([directory, "assets"]), addressed);
		});
		return macro null;
	}
	#end
}
