package hxn.assets;

import haxe.io.Bytes;

/** A source that can also open bounded pull streams. */
interface StreamingAssetSource extends AssetSource {
	function openStream(key:String):AssetStream<Bytes>;
}
