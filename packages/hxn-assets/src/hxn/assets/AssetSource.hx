package hxn.assets;

import haxe.io.Bytes;
import hxn.Future;

/** Reads a source key asynchronously. Applications can supply connected sources. */
interface AssetSource {
	public function read(path:String):Future<Bytes>;
}
