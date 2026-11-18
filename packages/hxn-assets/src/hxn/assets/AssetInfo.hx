package hxn.assets;

/** A logical address and its source key, with optional verified content identity. */
typedef AssetInfo = {
	var address:String;
	var path:String;
	@:optional var contentId:String;
	@:optional var mediaType:String;
	@:optional var group:String;
	@:optional var labels:Array<String>;
	@:optional var dependencies:Array<String>;
}
