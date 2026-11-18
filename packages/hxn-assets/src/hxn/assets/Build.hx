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
	static function systemPath(path:String):String {
		return Sys.systemName() == "Windows" ? StringTools.replace(path, "\\", "/") : path;
	}

	static function canonicalPath(path:String):String {
		return systemPath(FileSystem.fullPath(path));
	}

	static function within(root:String, path:String):Bool {
		final prefix = StringTools.endsWith(root, "/") ? root : root + "/";
		return path == root || StringTools.startsWith(path, prefix);
	}

	public static function catalog(directory:String, contentAddressed:Bool = false):Dynamic {
		final base = canonicalPath(directory);
		if (!FileSystem.isDirectory(base))
			throw "asset source is not a directory";
		final assets:Array<Dynamic> = [], names = new Map<String, Bool>();
		function walk(path:String, relative:String, ancestors:Array<String>):Void {
			final canonical = canonicalPath(path);
			if (!within(base, canonical))
				throw "asset symlink escapes its source directory";
			if (ancestors.indexOf(canonical) >= 0)
				throw "asset directory cycle";
			final next = ancestors.concat([canonical]);
			final entries = FileSystem.readDirectory(path);
			entries.sort(Reflect.compare);
			for (name in entries) {
				final source = Path.join([path, name]), key = relative == "" ? name : relative + "/" + name;
				final resolved = canonicalPath(source);
				if (!within(base, resolved))
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

	public static function stage(directory:String, output:String, contentAddressed:Bool = false, ?declared:AssetCatalog):Void {
		final source = FileSystem.exists(directory) ? canonicalPath(directory) : systemPath(FileSystem.absolutePath(directory));
		final destination = systemPath(FileSystem.absolutePath(output));
		if (within(source, destination))
			throw "asset output must be outside its source directory";
		final manifest = declared == null ? catalog(source, contentAddressed) : Json.parse(declared.toJson());
		FileSystem.createDirectory(destination);
		for (asset in (manifest.assets : Array<Dynamic>)) {
			if (RemoteUri.isUri(asset.path)) {
				RemoteUri.normalize(asset.path);
				if (asset.dynamicAsset != true)
					throw "remote assets must be dynamic";
				continue;
			}
			relativePath(asset.path);
			if (asset.dynamicAsset == true && !FileSystem.exists(Path.join([source, asset.path])))
				continue;
			final from = sourceFile(source, asset.path), into = Path.join([destination, asset.path]);
			FileSystem.createDirectory(Path.directory(into));
			File.copy(from, into);
			if (asset.contentId != null && "sha256:" + Sha256.make(File.getBytes(into)).toHex() != asset.contentId)
				throw 'asset changed after its catalog was generated: ${asset.path}';
		}
		File.saveContent(Path.join([destination, ".hxn-assets.json"]), Json.stringify(manifest));
	}

	/** Resolves a bundled source file within the portable asset namespace. */
	public static function relativePath(path:String):Void {
		if (haxe.io.Bytes.ofString(path).length > 4096 || ~/[\x00-\x1f\x7f\\:*?"<>|]/.match(path))
			throw "asset path must be a portable relative path";
		for (part in path.split("/")) {
			if (part == ""
				|| part == "."
				|| part == ".."
				|| StringTools.endsWith(part, ".")
				|| StringTools.endsWith(part, " ")
				|| haxe.io.Bytes.ofString(part).length > 240
				|| ~/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)/i.match(part))
				throw "asset path must be a portable relative path";
		}
		if (path == ".hxn-assets.json")
			throw "asset path uses the reserved catalog name";
	}

	/** Resolves a bundled source file within the portable asset namespace. */
	public static function sourceFile(directory:String, path:String):String {
		relativePath(path);
		if (!FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
			throw 'asset source directory does not exist: $directory';
		final root = canonicalPath(directory), source = Path.join([root, path]);
		if (!FileSystem.exists(source) || FileSystem.isDirectory(source))
			throw 'asset file does not exist: $path';
		final file = canonicalPath(source);
		if (!within(root, file))
			throw 'asset symlink escapes its source directory: $path';
		if (FileSystem.stat(file).size > 67108864)
			throw 'asset exceeds the 64 MiB read limit: $path';
		return file;
	}

	#if macro
	public static macro function register():haxe.macro.Expr {
		Compiler.define("hxn_assets_managed");
		final value = Context.definedValue("hxn_assets_dir"), source = value == null ? "assets" : value;
		final addressed = Context.defined("hxn_assets_content_addressed");
		var declared:Null<AssetCatalog> = null;
		Context.onGenerate(types -> {
			final entries:Array<AssetInfo> = [];
			for (type in types)
				switch (type) {
					case TInst(reference, _):
						final owner = reference.get();
						for (metadata in owner.meta.get())
							if (metadata.name == ":hxnAssetCatalog") {
								final json = switch (metadata.params[0].expr) {
									case EConst(CString(value, _)): value;
									case _: Context.error("invalid generated asset catalog metadata", metadata.pos);
								};
								for (asset in AssetCatalog.fromJson(json).all())
									entries.push(asset);
							}
					case _:
				}
			if (entries.length > 0)
				try {
					declared = new AssetCatalog(entries);
				} catch (error:Dynamic) {
					Context.error(Std.string(error), Context.currentPos());
				}
		});
		Context.onAfterGenerate(() -> {
			if (Compiler.getOutput() == "" || (!FileSystem.exists(source) && declared == null))
				return;
			final output = FileSystem.absolutePath(Compiler.getOutput());
			final directory = Context.defined("cpp") && !Context.defined("cppia") ? output : Path.directory(output);
			try {
				stage(source, Path.join([directory, "assets"]), addressed, declared);
			} catch (error:Dynamic) {
				Context.error(Std.string(error), Context.currentPos());
			}
		});
		return macro null;
	}
	#end
}
