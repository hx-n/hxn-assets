import haxe.io.Bytes;
import haxe.Exception;
import hxn.Future;
import hxn.assets.*;

class StreamCheck {
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

	public static function runChecks():Void {
		final source = new MemoryStreams(), loader = new AssetLoader(source, UriAssets.catalog());
		UriAssets.load(loader).await();
		check(UriAssets.Level.revision == 7, "HTTP URI typed value");
		final item = UriAssets.Updates.next().await();
		check(!item.done && item.text && item.value.revision == 8, "typed WS message");
		check(UriAssets.Download.next().await().value.toHex() == "0001ff", "HTTP byte chunk");
		UriAssets.unload();
		check(source.closed == 2, "generated unload closes both streams");
		loader.close();
		final driver = new ManyFrames();
		final stream = new AssetStream(driver, bytes -> bytes.length);
		var received = 0, ended = false;
		stream.map(length -> length + 1).map(length -> length - 1).listen(length -> {
			check(length == 1, "mapped payload");
			received++;
		}, () -> ended = true);
		check(ended && received == 10000 && driver.closed == 1, "synchronous stream trampoline or close ownership");
		final delayed = new DelayedFrame(), shared = new AssetStream(delayed, bytes -> bytes);
		final pending = shared.map(bytes -> bytes).map(bytes -> bytes).next();
		fails(() -> shared.next().await());
		shared.close();
		fails(() -> pending.await());
		check(delayed.closed == 1, "mapped stream cancellation");

		final listenerDriver = new DelayedFrame(), listening = new AssetStream(listenerDriver, bytes -> bytes);
		var cleanEnd = false, unexpectedError = false;
		listening.listen(_ -> {}, () -> cleanEnd = true, _ -> unexpectedError = true);
		listening.close();
		check(cleanEnd && !unexpectedError && listenerDriver.closed == 1, "explicit stream close should finish listeners normally");
		Sys.println("PASS: remote declarations, typed streams, backpressure, mapping and unload");
	}

	static function main():Void
		runChecks();
}

@:build(hxn.assets.Assets.build())
private class UriAssets {
	@:asset("http://assets.invalid/level.json") @:dynamicAsset
	public static var Level:{revision:Int};
	@:asset("wss://assets.invalid/updates") @:dynamicAsset
	public static var Updates:AssetStream<{revision:Int}>;
	@:asset("https://assets.invalid/download") @:dynamicAsset
	public static var Download:AssetStream<Bytes>;
}

private class MemoryStreams implements StreamingAssetSource {
	public var closed = 0;

	public function new() {}

	public function read(key:String):Future<Bytes>
		return Future.resolved(Bytes.ofString('{"revision":7}'));

	public function openStream(key:String):AssetStream<Bytes> {
		final bytes = StringTools.startsWith(key, "wss:") ? Bytes.ofString('{"revision":8}') : Bytes.ofHex("0001ff");
		return new AssetStream(new OneFrame(bytes, StringTools.startsWith(key, "wss:"), () -> closed++), bytes -> bytes);
	}
}

private class OneFrame implements AssetStreamDriver {
	final bytes:Bytes;
	final text:Bool;
	final onClose:Void->Void;
	var sent = false;

	public function new(bytes:Bytes, text:Bool, onClose:Void->Void) {
		this.bytes = bytes;
		this.text = text;
		this.onClose = onClose;
	}

	public function next():Future<StreamItem<Bytes>> {
		if (sent)
			return Future.resolved({done: true, value: null, text: false});
		sent = true;
		return Future.resolved({done: false, value: bytes, text: text});
	}

	public function close():Void
		onClose();
}

private class ManyFrames implements AssetStreamDriver {
	var left = 10000;

	public var closed = 0;

	final bytes = Bytes.ofHex("01");

	public function new() {}

	public function next():Future<StreamItem<Bytes>>
		return Future.resolved(--left >= 0 ? {done: false, value: bytes, text: false} : {done: true, value: null, text: false});

	public function close():Void
		closed++;
}

private class DelayedFrame implements AssetStreamDriver {
	public var closed = 0;

	final future = new Future<StreamItem<Bytes>>();

	public function new() {}

	public function next():Future<StreamItem<Bytes>>
		return future;

	public function close():Void {
		closed++;
		@:privateAccess future.settle(null, new Exception("closed"));
	}
}
