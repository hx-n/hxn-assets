package hxn.assets;

@:noCompletion
class RemoteUri {
	public static function isUri(value:String):Bool
		return new EReg("^[A-Za-z][A-Za-z0-9+.-]*://", "").match(value);

	public static function normalize(value:String):String {
		final scheme = new EReg("^(https?|wss?)://([^/?#]+)([^#]*)$", "i");
		var invalid = value.length > 8192;
		for (i in 0...value.length)
			if (value.charCodeAt(i) <= 32 || value.charCodeAt(i) == 127)
				invalid = true;
		if (invalid || !scheme.match(value) || scheme.matched(2).indexOf("@") >= 0)
			throw "remote assets require an HTTP(S) or WS(S) URI without embedded credentials or fragments";
		return scheme.matched(1).toLowerCase() + value.substr(value.indexOf(":"));
	}

	public static function socket(value:String):Bool
		return StringTools.startsWith(value, "ws://") || StringTools.startsWith(value, "wss://");
}
