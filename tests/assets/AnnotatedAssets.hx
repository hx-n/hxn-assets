@:build(hxn.assets.Assets.build())
class AnnotatedAssets {
	@:asset("one", "same")
	@:contentAddressed
	public static var One:String;

	@:asset("two", "second")
	@:contentAddressed("sha256")
	public static var Two:String;
}
