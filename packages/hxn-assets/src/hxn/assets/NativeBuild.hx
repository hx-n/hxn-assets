package hxn.assets;

#if macro
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import sys.FileSystem;
#end

/** Selects the packaged graph implementation without a separate dependency. */
class NativeBuild {
	#if macro
	public static function register():Void {
		if (!Context.defined("hl") && !Context.defined("cpp"))
			return;
		var root = Context.resolvePath("hxn/assets/NativeBuild.hx");
		for (_ in 0...4)
			root = Path.directory(root);
		final option = Context.definedValue("hxn_assets_jit");
		final requested = option == null || option == "auto" ? "auto" : switch (option) {
			case "1", "true", "on": "on";
			case "0", "false", "off": "off";
			case _:
				Context.fatalError("hxn_assets_jit must be auto, on or off", Context.currentPos());
				"off";
		};
		final runtime = Context.defined("hl") ? "hl" : "cpp";
		final triple = @:privateAccess hxn.Bind.triple(runtime);
		final variant = Path.join([root, "variants", "jit"]);
		final supported = FileSystem.exists(Path.join([variant, "native", triple]));
		if (requested == "on" && !supported)
			Context.fatalError('the hxn-assets package has no JIT build for $triple; use --no-jit', Context.currentPos());
		final jit = requested == "on" || (requested == "auto" && supported);
		Compiler.addClassPath(jit ? variant : root);
		hxn.Bind.lib(jit ? "assets_jit" : "assets");
	}
	#end
}
