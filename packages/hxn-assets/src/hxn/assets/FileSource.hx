package hxn.assets;

import haxe.io.Bytes;
import hxn.Future;
import hxn.file.Storage;

/** Borrows a Storage and reads from its read-only bundled asset root. */
class FileSource implements AssetSource {
	final storage:Storage;

	public function new(storage:Storage) {
		this.storage = storage;
	}

	public function read(path:String):Future<Bytes>
		return storage.readAsset(path);
}
