import haxe.io.Bytes;
import haxe.Exception;
import haxe.crypto.Sha256;
import hxn.Future;
import hxn.assets.*;

class AssetsCheck {
	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function fails(call:Void->Void):Void {
		var failed = false;
		try
			call()
		catch (_:Dynamic)
			failed = true;
		if (!failed)
			throw "expected failure";
	}

	static function main():Void {
		final entries:Array<AssetInfo> = [
			{
				address: "root",
				path: "root",
				dependencies: ["dep"],
				labels: ["visible"],
				group: "world"
			},
			{address: "dep", path: "dep", labels: ["shared"]}
		];
		final catalog = new AssetCatalog(entries);
		entries[0].dependencies.push("missing");
		catalog.get("root").dependencies.push("missing");
		check(catalog.order("root")[0].address == "dep", "dependency order or snapshot mutation");
		check(catalog.labels(["shared"]).length == 1 && catalog.group("world").length == 1, "catalog lookups");
		check(AssetCatalog.fromJson(catalog.toJson()).all().length == 2, "catalog serialization");
		fails(() -> new AssetCatalog([{address: "a", path: "a", dependencies: ["b"]}]));
		fails(() -> new AssetCatalog([
			{address: "a", path: "a", dependencies: ["b"]},
			{address: "b", path: "b", dependencies: ["a"]}
		]));
		fails(() -> new AssetCatalog([{address: "a", path: "a"}, {address: "a", path: "other"}]));
		final source = new ImmediateSource();
		final loader = new AssetLoader(source, catalog, 8);
		check(loader.load("root").await().toString() == "root", "load root");
		check(source.calls.join(",") == "dep,root", "dependencies before payload");
		final returned = loader.load("root").await();
		returned.set(0, 0);
		check(loader.load("root").await().toString() == "root", "returned bytes alias cache");
		check(loader.cachedBytes <= 8, "cache budget");
		loader.unload("root");
		loader.load("root").await();
		check(source.calls.length == 3, "unload/reload");
		loader.close();
		fails(() -> loader.load("root").await());
		final payload = Bytes.ofString("same");
		final cid = "sha256:" + Sha256.make(payload).toHex();
		final addressed = AnnotatedAssets.catalog();
		check(AnnotatedAssets.addresses.One == "one" && AnnotatedAssets.addresses.Two == "two", "generated address constants");
		check(addressed.get(AnnotatedAssets.addresses.One).contentId == cid
			&& addressed.get(AnnotatedAssets.addresses.Two).contentId == cid,
			"compile-time content identity");
		check(PlainAssets.catalog().get(PlainAssets.addresses.Hello).contentId == null, "hashing must be opt-in");
		final grouped = GroupedAssets.catalog();
		check(grouped.order(GroupedAssets.addresses.Hello)[0].address == GroupedAssets.addresses.Base, "annotated dependencies");
		check(grouped.get(GroupedAssets.addresses.Hello).contentId != null, "class content identity opt-in");
		check(grouped.group("world").length == 1 && grouped.labels(["visible", "shared"]).length == 1, "annotated group and labels");
		check(grouped.get(GroupedAssets.addresses.Hello).mediaType == "text/plain", "annotated media type");
		final delayed = new DelayedSource();
		final shared = new AssetLoader(delayed, addressed);
		final first = shared.load(AnnotatedAssets.addresses.One), second = shared.load(AnnotatedAssets.addresses.Two);
		check(delayed.calls == 1, "in-flight content deduplication");
		delayed.complete(0, payload);
		check(first.await().toString() == "same" && second.await().toString() == "same", "shared payload");
		final stale = new DelayedSource();
		final generations = new AssetLoader(stale, new AssetCatalog([{address: "a", path: "a"}]));
		final old = generations.load("a");
		generations.unload("a");
		final fresh = generations.load("a");
		check(stale.calls == 2, "invalidation must not reuse old in-flight data");
		stale.complete(0, Bytes.ofString("old"));
		stale.complete(1, Bytes.ofString("new"));
		check(old.await().toString() == "old" && fresh.await().toString() == "new", "generation results");
		check(generations.load("a").await().toString() == "new", "stale completion replaced cache");
		final wrong = new AssetLoader(new ImmediateSource(), new AssetCatalog([{address: "bad", path: "wrong", contentId: cid}]));
		fails(() -> wrong.load("bad").await());
		fails(() -> wrong.load("bad").await());
		check(wrong.cachedBytes == 0, "mismatched content was cached");
		Sys.println("PASS: catalog, dependencies, content identity, cache and invalidation");
	}
}

private class ImmediateSource implements AssetSource {
	public final calls:Array<String> = [];

	public function new() {}

	public function read(path:String):Future<Bytes> {
		calls.push(path);
		return Future.resolved(Bytes.ofString(path));
	}
}

private class DelayedSource implements AssetSource {
	public var calls = 0;

	final futures:Array<Future<Bytes>> = [];

	public function new() {}

	public function read(path:String):Future<Bytes> {
		calls++;
		final future = new Future<Bytes>();
		futures.push(future);
		return future;
	}

	public function complete(index:Int, bytes:Bytes):Void {
		@:privateAccess futures[index].settle(bytes, null);
	}
}
