package hxn.assets.cli;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import hxn.assets.Build;

/** Commands supplied by the installed hxn-assets haxelib. */
class Tool {
	static function main():Void {
		try {
			final request:Dynamic = Json.parse(Sys.stdin().readAll().toString());
			if (request.version != 1 || request.kind != "command")
				throw "unsupported hxn-assets plugin request";
			final args:Array<String> = request.arguments;
			final command = args.shift();
			if (command == null || command == "help" || command == "--help") {
				Sys.println("hxn assets catalog --source <directory> --out <catalog.json> [--content-addressed]");
				Sys.println("hxn assets stage --source <directory> --out <directory> [--content-addressed]");
				return;
			}
			var source = "assets",
				output:Null<String> = null,
				addressed = false;
			while (args.length > 0)
				switch (args.shift()) {
					case "--source":
						source = args.shift();
						if (source == null)
							throw "--source needs a directory";
					case "--out":
						output = args.shift();
						if (output == null)
							throw "--out needs a path";
					case "--content-addressed":
						addressed = true;
					case flag:
						throw 'unknown assets option $flag';
				}
			if (output == null)
				throw "--out is required";
			switch (command) {
				case "catalog":
					FileSystem.createDirectory(haxe.io.Path.directory(FileSystem.absolutePath(output)));
					File.saveContent(output, Json.stringify(Build.catalog(source, addressed)));
				case "stage":
					Build.stage(source, output, addressed);
				case _:
					throw 'unknown assets command $command';
			}
		} catch (error:Dynamic) {
			Sys.stderr().writeString('hxn-assets: ${Std.string(error)}\n');
			Sys.exit(2);
		}
	}
}
