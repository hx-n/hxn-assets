@:contentAddressed
@:build(hxn.assets.Assets.build())
class GroupedAssets {
	@:asset("nested/hello.txt")
	@:assetGroup("world")
	@:assetLabels("visible", "shared")
	@:assetMediaType("text/plain")
	@:assetDependsOn(Base)
	public static var Hello:String;

	@:asset("base", "same")
	public static var Base:String;
}
