package hxn.assets.cli;

import hxn.cli.Context;
import hxn.cli.Failure;

/** Copies a directory of assets into another directory, with its catalog. **/
class StageCommand implements hxn.cli.Command {
	/** The directory of the assets. **/
	@:option @:value("directory") var source = "assets";

	/** The directory to copy them into. **/
	@:option @:value("directory") var out:Null<String>;

	/** Gives each asset a SHA-256 digest of its contents. **/
	@:option var contentAddressed = false;

	public function run(context:Context):Int {
		if (out == null)
			throw new Failure("--out is required", 2);
		Build.stage(source, out, contentAddressed);
		return 0;
	}
}
