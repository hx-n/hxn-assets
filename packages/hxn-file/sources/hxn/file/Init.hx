package hxn.file;

#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;
#end

/** Installs browser agents and stages explicitly selected bundled files. */
class Init {
	public static macro function register():haxe.macro.Expr {
		final triple = Context.definedValue("hxn_triple");
		if (triple != null && (triple.indexOf("android") >= 0 || triple.indexOf("ios") >= 0))
			Compiler.define("hxn_file_mobile");
		final selected = Context.definedValue("hxn_assets_dir");
		final assets = selected == null ? "assets" : selected;
		Context.onAfterGenerate(() -> {
			final output = FileSystem.absolutePath(Compiler.getOutput());
			final directory = Context.defined("cpp") && !Context.defined("cppia") ? output : Path.directory(output);
			FileSystem.createDirectory(directory);
			if (!Context.defined("hxn_assets_managed") && FileSystem.exists(assets) && FileSystem.isDirectory(assets))
				copy(assets, Path.join([directory, "assets"]));
			if (Context.defined("wasm") || Context.defined("emscripten")) {
				var root = Context.resolvePath("hxn/file/Init.hx");
				for (_ in 0...4)
					root = Path.directory(root);
				final agent = Path.join([root, "page", "hxn_file.mjs"]);
				if (!FileSystem.exists(agent))
					Context.fatalError("hxn-file package has no browser agent", Context.currentPos());
				File.copy(agent, Path.join([directory, "hxn_file.mjs"]));
			}
		});
		return macro null;
	}

	#if macro
	static function copy(from:String, into:String):Void {
		if (FileSystem.exists(into) && FileSystem.fullPath(from) == FileSystem.fullPath(into))
			return;
		FileSystem.createDirectory(into);
		for (name in FileSystem.readDirectory(from)) {
			final source = Path.join([from, name]), destination = Path.join([into, name]);
			if (FileSystem.isDirectory(source))
				copy(source, destination);
			else
				File.copy(source, destination);
		}
	}
	#end
}
