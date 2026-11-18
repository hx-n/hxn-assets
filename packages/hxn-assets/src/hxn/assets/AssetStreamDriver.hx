package hxn.assets;

import haxe.io.Bytes;
import hxn.Future;

/** Pull transport for byte chunks or complete messages; it owns its connection. */
interface AssetStreamDriver {
	function next():Future<StreamItem<Bytes>>;
	function close():Void;
}
