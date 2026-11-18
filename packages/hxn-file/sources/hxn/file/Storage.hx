package hxn.file;

import haxe.io.Bytes;
import haxe.io.Path;
import hxn.Future;
import hxn.Unit;

/** Bundled read-only files and application-scoped saves and preferences. */
class Storage {
	var backend:Null<StorageBackend>;

	public function new(application:String, ?options:StorageOptions) {
		if (options == null)
			options = {};
		var assets = options.assetDirectory;
		if (assets == null) {
			#if (wasm || emscripten || android || ios || iphoneos || iphonesim || hxn_file_mobile)
			assets = "";
			#else
			final program = Sys.programPath();
			assets = program.indexOf(".app/") >= 0 ? "" : Path.join([Path.directory(program), "assets"]);
			#end
		}
		backend = new StorageBackend(application, assets, options.dataRoot == null ? "" : options.dataRoot);
	}

	function live():StorageBackend {
		if (backend == null)
			throw "storage is closed";
		return backend;
	}

	/** Reads a path relative to the application's bundled asset root. */
	public function readAsset(path:String):Future<Bytes>
		return live().readAsset(path);

	/** Missing saves reject the future. */
	public function readSave(path:String):Future<Bytes>
		return live().readSave(path);

	/** Copies bytes before returning and replaces the whole save atomically. */
	public function writeSave(path:String, bytes:Bytes):Future<Unit>
		return live().writeSave(path, bytes);

	public function deleteSave(path:String):Future<Bool>
		return live().deleteSave(path);

	public function getPreference(key:String):Future<Preference>
		return live().getPreference(key);

	public function setPreference(key:String, value:String):Future<Unit>
		return live().setPreference(key, value);

	public function deletePreference(key:String):Future<Bool>
		return live().deletePreference(key);

	/** Already-started operations retain their state and complete normally. */
	public function close():Void {
		if (backend != null) {
			backend.close();
			backend = null;
		}
	}
}
