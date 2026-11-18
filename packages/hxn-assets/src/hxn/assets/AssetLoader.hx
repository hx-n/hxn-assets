package hxn.assets;

import haxe.io.Bytes;
import haxe.crypto.Sha256;
import haxe.ds.StringMap;
import hxn.Future;
import haxe.Exception;

/** Asynchronous dependency loading with a bounded byte cache on the Haxe event thread. */
class AssetLoader {
	final source:AssetSource;
	final catalog:AssetCatalog;
	final maximum:Int;
	final maximumPending:Int;
	final cache = new StringMap<{bytes:Bytes, tick:Int}>();
	final pending = new StringMap<{future:Null<Future<Bytes>>, epoch:Int, generation:Int}>();
	final generations = new StringMap<Int>();
	var tick = 0;
	var held = 0;
	var active = 0;
	var closed = false;
	var epoch = 0;

	public var cachedBytes(get, never):Int;

	function get_cachedBytes():Int
		return held;

	public function new(source:AssetSource, catalog:AssetCatalog, maxCacheBytes:Int = 67108864, maxPending:Int = 16) {
		if (source == null || catalog == null || maxCacheBytes < 0 || maxPending < 1)
			throw "invalid asset loader options";
		this.source = source;
		this.catalog = catalog;
		maximum = maxCacheBytes;
		maximumPending = maxPending;
	}

	public function load(address:String):Future<Bytes> {
		if (closed)
			return Future.rejected(new Exception("asset loader is closed"));
		var order:Array<AssetInfo>;
		try {
			order = catalog.order(address);
		} catch (error:Dynamic) {
			return Future.rejected(new Exception(Std.string(error)));
		}
		var loaded = Future.resolved(Bytes.alloc(0));
		for (asset in order) {
			final selected = asset;
			loaded = loaded.flatMap(_ -> buffer(selected));
		}
		return loaded.map(bytes -> bytes.sub(0, bytes.length));
	}

	/** Loads byte dependencies, then opens a pull stream without caching its unbounded sequence. */
	public function openStream(address:String):Future<AssetStream<Bytes>> {
		if (closed)
			return Future.rejected(new Exception("asset loader is closed"));
		try {
			final order = catalog.order(address), asset = order.pop();
			if (!Std.isOfType(source, StreamingAssetSource))
				return Future.rejected(new Exception("asset source cannot open streams"));
			if (asset.contentId != null)
				return Future.rejected(new Exception("an unbounded stream has no whole-content digest"));
			var ready = Future.resolved(Bytes.alloc(0));
			for (dependency in order) {
				final selected = dependency;
				ready = ready.flatMap(_ -> buffer(selected));
			}
			return ready.map(_ -> {
				if (closed)
					throw "asset loader is closed";
				return (cast source : StreamingAssetSource).openStream(asset.path);
			});
		} catch (error:Dynamic) {
			return Future.rejected(new Exception(Std.string(error)));
		}
	}

	function key(asset:AssetInfo):String
		return asset.contentId == null ? "address:" + asset.address : asset.contentId;

	function buffer(asset:AssetInfo):Future<Bytes> {
		if (closed)
			return Future.rejected(new Exception("asset loader is closed"));
		if (asset.streamAsset == true)
			return Future.rejected(new Exception("stream assets require openStream"));
		if (hxn.Log.enabled(hxn.LogLevel.Debug))
			hxn.Log.debug('loading ${asset.address}', "hxn.assets");
		final id = key(asset), found = cache.get(id);
		if (found != null) {
			found.tick = ++tick;
			return Future.resolved(found.bytes);
		}
		final waiting = pending.get(id);
		final generation = generations.exists(id) ? generations.get(id) : 0;
		if (waiting != null && waiting.epoch == epoch && waiting.generation == generation)
			return waiting.future == null ? Future.rejected(new Exception("asset source reentered its own load")) : waiting.future;
		if (active >= maximumPending)
			return Future.rejected(new Exception("too many pending asset loads"));
		final slot:{future:Null<Future<Bytes>>, epoch:Int, generation:Int} = {future: null, epoch: epoch, generation: generation};
		pending.set(id, slot);
		active++;
		final started = epoch;
		var read:Future<Bytes>;
		try {
			read = source.read(asset.path);
			if (read == null)
				throw "asset source returned no future";
		} catch (error:Dynamic) {
			if (pending.get(id) == slot)
				pending.remove(id);
			active--;
			return Future.rejected(new Exception(Std.string(error)));
		}
		final result = read.map(bytes -> {
			if (bytes == null)
				throw "asset source returned no bytes";
			if (bytes.length > 67108864)
				throw "asset exceeds the 64 MiB read limit";
			final owned = bytes.sub(0, bytes.length);
			if (asset.contentId != null && "sha256:" + Sha256.make(owned).toHex() != asset.contentId)
				throw 'content digest mismatch: ${asset.address}';
			if (!closed
				&& started == epoch
				&& generation == (generations.exists(id) ? generations.get(id) : 0)
				&& maximum > 0
				&& owned.length <= maximum) {
				while (held + owned.length > maximum)
					evict();
				cache.set(id, {bytes: owned, tick: ++tick});
				held += owned.length;
			}
			if (pending.get(id) == slot)
				pending.remove(id);
			active--;
			return owned;
		}).recover(error -> {
			if (pending.get(id) == slot)
				pending.remove(id);
			active--;
			throw error;
		});
		slot.future = result;
		return result;
	}

	function evict():Void {
		var oldest:Null<String> = null, age = 0;
		for (id in cache.keys()) {
			final value = cache.get(id);
			if (oldest == null || value.tick < age) {
				oldest = id;
				age = value.tick;
			}
		}
		if (oldest != null) {
			held -= cache.get(oldest).bytes.length;
			cache.remove(oldest);
		}
	}

	public function unload(address:String):Void {
		final id = key(catalog.get(address)), found = cache.get(id);
		if (found != null) {
			held -= found.bytes.length;
			cache.remove(id);
		}
		generations.set(id, (generations.exists(id) ? generations.get(id) : 0) + 1);
	}

	/** Clears the loader-owned cache; bytes already returned to callers remain valid. */
	public function clear():Void {
		cache.clear();
		held = 0;
		epoch++;
		generations.clear();
	}

	public function close():Void {
		closed = true;
		clear();
	}
}
