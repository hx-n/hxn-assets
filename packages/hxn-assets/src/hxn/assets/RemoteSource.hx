package hxn.assets;

import haxe.io.Bytes;
import haxe.Exception;
import hxn.Future;
import hxn.file.RemoteBackend;

/** HTTP(S) values and streams, and WS(S) message streams; optional borrowed fallback for local keys. */
class RemoteSource implements StreamingAssetSource {
	final options:String;
	final local:Null<AssetSource>;

	public function new(?options:RemoteOptions, ?local:AssetSource) {
		final value:Dynamic = {};
		if (options != null) {
			if (options.timeoutMs != null)
				value.timeoutMs = options.timeoutMs;
			if (options.maxBytes != null)
				value.maxBytes = options.maxBytes;
			if (options.chunkBytes != null)
				value.chunkBytes = options.chunkBytes;
			if (options.protocols != null)
				value.protocols = options.protocols;
			if (options.caCertificates != null)
				value.caCertificates = options.caCertificates;
			if (options.headers != null) {
				final headers:Dynamic = {};
				for (name in options.headers.keys())
					Reflect.setField(headers, name, options.headers.get(name));
				value.headers = headers;
			}
		}
		this.options = haxe.Json.stringify(value);
		this.local = local;
	}

	public function read(key:String):Future<Bytes> {
		if (!RemoteUri.isUri(key))
			return local == null ? Future.rejected(new Exception("relative asset key requires a local source")) : local.read(key);
		try {
			final uri = RemoteUri.normalize(key);
			if (RemoteUri.socket(uri))
				return Future.rejected(new Exception("WS(S) assets require an AssetStream"));
			final backend = new RemoteBackend(uri, options);
			return backend.read().map(bytes -> {
				backend.close();
				return bytes;
			}).recover(error -> {
				backend.close();
				throw error;
			});
		} catch (error:Dynamic) {
			return Future.rejected(new Exception(Std.string(error)));
		}
	}

	public function openStream(key:String):AssetStream<Bytes> {
		final uri = RemoteUri.normalize(key);
		return new AssetStream(new RemoteDriver(new RemoteBackend(uri, options)), bytes -> bytes);
	}
}

private class RemoteDriver implements AssetStreamDriver {
	var backend:Null<RemoteBackend>;

	public function new(backend:RemoteBackend) {
		this.backend = backend;
	}

	public function next():Future<StreamItem<Bytes>> {
		if (backend == null)
			return Future.rejected(new Exception("remote asset stream is closed"));
		return backend.next().map(frame -> {done: frame.end, value: frame.end ? null : frame.bytes, text: frame.text});
	}

	public function close():Void {
		if (backend != null) {
			backend.cancel();
			backend.close();
			backend = null;
		}
	}
}
