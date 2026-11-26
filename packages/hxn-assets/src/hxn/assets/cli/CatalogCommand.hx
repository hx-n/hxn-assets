package hxn.assets.cli;

import haxe.Json;
import haxe.io.Path;
import hxn.cli.Context;
import hxn.cli.Failure;
import sys.FileSystem;
import sys.io.File;

/** Writes the catalog of every file in a directory of assets, as JSON. **/
class CatalogCommand implements hxn.cli.Command {
	/** The directory of the assets. **/
	@:option @:value("directory") var source = "assets";

	/** The catalog file to write. **/
	@:option @:value("catalog.json") var out:Null<String>;

	/** Gives each asset a SHA-256 digest of its contents. **/
	@:option var contentAddressed = false;

	public function run(context:Context):Int {
		if (out == null)
			throw new Failure("--out is required", 2);
		FileSystem.createDirectory(Path.directory(FileSystem.absolutePath(out)));
		File.saveContent(out, Json.stringify(Build.catalog(source, contentAddressed)));
		return 0;
	}
}
