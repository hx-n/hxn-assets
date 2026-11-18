import TypedAssets.LevelData;

@:build(hxn.assets.Assets.build())
class LiveAssets {
	@:asset("live", "runtime/level.payload") @:dynamicAsset
	public static var Level:LevelData;

	@:asset("raw", "runtime/opaque.payload") @:dynamicAsset
	public static var Raw:Dynamic;

	@:asset("count", "runtime/count.payload") @:dynamicAsset @:assetDecode(LiveAssets.decodeCount)
	public static var Count:Int;

	@:asset("image", "runtime/image.png") @:dynamicAsset
	public static var Image:hxn.assets.ImageData;

	@:asset("json", "runtime/freeform.payload") @:dynamicAsset @:assetFormat("json")
	public static var Json:Dynamic;

	public static function decodeCount(bytes:haxe.io.Bytes):Int {
		final value = Std.parseInt(bytes.toString());
		if (value == null)
			throw "invalid count";
		return value;
	}
}
