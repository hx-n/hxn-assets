package hxn.assets;

/** Bounded native/page transport settings; credentials are supplied by the application at runtime. */
typedef RemoteOptions = {
	?timeoutMs:Int,
	?maxBytes:Int,
	?chunkBytes:Int,
	?headers:Map<String, String>,
	?protocols:Array<String>,
	?caCertificates:Array<String>
}
