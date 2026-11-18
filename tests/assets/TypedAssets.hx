import haxe.io.Bytes;
import hxn.assets.ImageData;

typedef LevelData = {
	var name:String;
	var lives:Int;
	var spawn:{x:Float, y:Int};
	var tags:Array<String>;
	@:optional var note:String;
}

@:build(hxn.assets.Assets.build())
class TypedAssets {
	@:asset("levels/start.json") @:contentAddressed
	public static var Start:LevelData;

	@:asset("levels/start.json")
	public static var Untyped:Dynamic;

	@:asset("nested/hello.txt")
	public static var Text:String;

	@:asset("payload.bin")
	public static var Binary:Bytes;

	@:asset("pixels.png")
	public static var Pixels:ImageData;

	@:asset("pixels.png")
	public static var EncodedImage:Bytes;

	@:asset("data.hxs") @:assetFormat("haxe")
	public static var Serialized:Array<Int>;

	@:asset("scene.xml")
	public static var Scene:Xml;
	@:asset("palette.png")
	public static var Palette:ImageData;
}
