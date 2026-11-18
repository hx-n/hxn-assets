import hxn.assets.AssetLoader;
import hxn.assets.FileSource;
import hxn.file.Storage;
import hxn.file.StorageOptions;

/** Real storage integration for metadata-generated catalogs. */
class FilesCheck {
	static function main():Void {
		TypedCheck.runChecks();
		final options:StorageOptions = {};
		#if (!wasm && !emscripten)
		if (Sys.args().length > 0)
			options.assetDirectory = Sys.args()[0];
		if (Sys.args().length > 1)
			options.dataRoot = Sys.args()[1];
		#end
		final files = new Storage("org.hxn.assets.check", options);
		final loader = new AssetLoader(new FileSource(files), AnnotatedAssets.catalog());
		loader.load(AnnotatedAssets.addresses.One)
			.flatMap(bytes -> {
				if (bytes.toString() != "same")
					throw "wrong first annotated payload";
				return loader.load(AnnotatedAssets.addresses.Two);
			})
			.flatMap(bytes -> {
				if (bytes.toString() != "same")
					throw "wrong second annotated payload";
				return files.writeSave("catalog.bin", bytes);
			})
			.flatMap(_ -> files.readSave("catalog.bin"))
			.then(bytes -> {
				if (bytes.toString() != "same")
					throw "wrong persisted annotated payload";
				loader.close();
				files.close();
				Sys.println("PASS: annotated assets, content verification, FileSource and save round trip");
				hxn.Loop.exit(0);
			}, error -> {
				Sys.stderr().writeString(Std.string(error) + "\n");
				Sys.exit(1);
			});
	}
}
