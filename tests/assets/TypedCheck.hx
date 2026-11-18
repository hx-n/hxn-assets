import haxe.io.Bytes;
import hxn.Future;
import hxn.assets.*;

class TypedCheck {
	static function check(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function fails(call:Void->Void):Void {
		var failed = false;
		try
			call()
		catch (_:Dynamic)
			failed = true;
		check(failed, "expected failure");
	}

	static function main():Void {
		runChecks();
		Sys.println("PASS: embedded typed JSON, text, bytes, PNG and dynamic decoding/type validation");
	}

	public static function runChecks():Void {
		KnowledgeCheck.runChecks();
		check(TypedAssets.Start.name == "start" && TypedAssets.Start.lives == 3, "typed embedded JSON");
		check(TypedAssets.Start.spawn.x == 1.5 && TypedAssets.Start.tags[0] == "first", "nested JSON shape");
		check(TypedAssets.Serialized.join(",") == "1,2,3", "embedded Haxe-serialized values");
		check(TypedAssets.Scene.firstElement().get("name") == "start", "embedded XML");
		check(TypedAssets.Untyped.name == "start", "Dynamic embedded JSON");
		check(TypedAssets.Text == "bundled hello\n", "embedded text value");
		check(TypedAssets.Binary.toHex() == "0001ff0009", "embedded binary bytes");
		check(TypedAssets.Palette.pixels.toHex() == "ff0000ff0000ff80", "indexed PNG, first-row Up filter and transparency");
		check(TypedAssets.Pixels.width == 2 && TypedAssets.Pixels.height == 1, "decoded PNG dimensions");
		check(TypedAssets.Pixels.pixels.toHex() == "ff0000ff00ff0080", "decoded RGBA8 pixels and alpha");
		check(TypedAssets.addresses.Start == "Start" && TypedAssets.catalog().get(TypedAssets.addresses.Start).contentId != null,
			"separate addresses and content identity");
		fails(() -> {
			final value = LiveAssets.Level;
		});
		final source = new TypedSource();
		final loader = new AssetLoader(source, LiveAssets.catalog());
		LiveAssets.load(loader).await();
		check(LiveAssets.Level.lives == 3 && LiveAssets.Level.spawn.y == 2, "expected runtime structure decoding");
		check((cast LiveAssets.Raw : Bytes).toHex() == "0001ff", "untyped dynamic asset needs application decoding");
		check(LiveAssets.Count == 42, "custom runtime decoder");
		check(LiveAssets.Image.pixels.toHex() == TypedAssets.Pixels.pixels.toHex(), "typed runtime image decoding");
		check(LiveAssets.Json.enabled == true, "explicit dynamic JSON format");
		LiveAssets.unload();
		fails(() -> {
			final value = LiveAssets.Level;
		});
		source.bad = true;
		loader.clear();
		fails(() -> LiveAssets.load(loader).await());
		fails(() -> {
			final value = LiveAssets.Raw;
		});
		loader.close();
		final delayed = new DelayedTypedSource();
		final changing = new AssetLoader(delayed, ChangingAssets.catalog(), 0);
		final old = ChangingAssets.load(changing);
		ChangingAssets.unload();
		changing.clear();
		final fresh = ChangingAssets.load(changing);
		delayed.complete(1, 2);
		fresh.await();
		delayed.complete(0, 1);
		fails(() -> old.await());
		check(ChangingAssets.Value.revision == 2, "superseded runtime load replaced current data");
		ChangingAssets.unload();
		changing.clear();
		final discarded = ChangingAssets.load(changing);
		ChangingAssets.unload();
		delayed.complete(2, 3);
		fails(() -> discarded.await());
		fails(() -> {
			final value = ChangingAssets.Value;
		});
		changing.close();
	}
}

private class TypedSource implements AssetSource {
	public var bad = false;

	public function new() {}

	public function read(path:String):Future<Bytes> {
		return Future.resolved(switch (path) {
			case "runtime/level.payload": Bytes.ofString(bad ? '{"name":"bad","lives":"wrong","spawn":{"x":0,"y":1},"tags":[]}' : '{"name":"live","lives":3,"spawn":{"x":1.5,"y":2},"tags":[]}');
			case "runtime/opaque.payload": Bytes.ofHex("0001ff");
			case "runtime/count.payload": Bytes.ofString("42");
			case "runtime/image.png": TypedAssets.EncodedImage;
			case "runtime/freeform.payload": Bytes.ofString('{"enabled":true}');
			case _: throw "unknown source key";
		});
	}
}

@:build(hxn.assets.Assets.build())
private class ChangingAssets {
	@:asset("runtime/revision.json") @:dynamicAsset
	public static var Value:{revision:Int};
}

private class DelayedTypedSource implements AssetSource {
	final futures:Array<Future<Bytes>> = [];

	public function new() {}

	public function read(path:String):Future<Bytes> {
		final future = new Future<Bytes>();
		futures.push(future);
		return future;
	}

	public function complete(index:Int, revision:Int):Void {
		@:privateAccess futures[index].settle(Bytes.ofString(haxe.Json.stringify({revision: revision})), null);
	}
}
