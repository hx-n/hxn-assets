package hxn.assets.cli;

import hxn.cli.Context;
import hxn.cli.Failure;

/**
	Compiles a Haxe program with hxn-assets. `--jit` and `--no-jit` choose a
	prebuilt variant of the graph engine: with JIT compilation of queries, or
	with scalar queries. Without either, the compiler takes the JIT variant
	where the package has it, and the scalar one elsewhere.
**/
class BuildCommand implements hxn.cli.Command {
	/** Takes the JIT variant. **/
	@:option var jit = false;

	/** Takes the scalar variant. **/
	@:option var noJit = false;

	/** The arguments for Haxe, or a program file such as app.hxml. **/
	@:arg @:raw @:value("haxe arguments") var compiler:Array<String> = [];

	public function run(context:Context):Int {
		if (jit && noJit)
			throw new Failure("choose --jit or --no-jit", 2);
		if (compiler.length == 0)
			throw new Failure("build needs Haxe arguments or an hxml file", 2);
		var arguments = ["-lib", "hxn-assets"].concat(compiler);
		if (jit || noJit)
			arguments = arguments.concat(["-D", "hxn_assets_jit=" + (jit ? "on" : "off")]);
		return Sys.command("haxe", arguments);
	}
}
