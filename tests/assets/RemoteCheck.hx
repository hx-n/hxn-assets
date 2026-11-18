import haxe.io.Bytes;
import haxe.Exception;
import hxn.Future;
import hxn.Unit;
import hxn.assets.*;

class RemoteCheck {
	static function check(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function failure<T>(future:Future<T>):Future<Unit> {
		return future.map(_ -> false).recover(_ -> Future.resolved(true)).map(failed -> {
			check(failed, "expected remote failure");
			return Nothing;
		});
	}

	static function collect(stream:AssetStream<Bytes>, into:BytesBuffer):Future<Bytes> {
		return stream.next().flatMap(item -> {
			if (item.done)
				return Future.resolved(into.getBytes());
			into.add(item.value);
			return collect(stream, into);
		});
	}

	static function main():Void {
		TypedCheck.runChecks();
		StreamCheck.runChecks();
		final options:RemoteOptions = {
			timeoutMs: 5000,
			maxBytes: 1024,
			chunkBytes: 7,
			protocols: ["asset.v1"]
		};
		#if (!wasm && !emscripten)
		options.caCertificates = [RemoteConfig.ca];
		#end
		final source = new RemoteSource(options), loader = new AssetLoader(source, RemoteAssets.catalog());
		RemoteAssets.load(loader)
			.flatMap(_ -> {
				check(RemoteAssets.Snapshot.revision == 23, "HTTPS typed snapshot");
				return RemoteAssets.Messages.next();
			})
			.flatMap(item -> {
				check(item.text && item.value.toString() == "hello", "WS text message");
				return RemoteAssets.Messages.next();
			})
			.flatMap(item -> {
				check(!item.text && item.value.toHex() == "0001ff", "WS binary message");
				return RemoteAssets.Messages.next();
			})
			.flatMap(item -> {
				check(!item.done && item.value.length == 0 && !item.text, "WS empty binary message");
				return RemoteAssets.Messages.next();
			})
			.flatMap(item -> {
				check(!item.done && item.value.length == 0 && item.text, "WS empty text message");
				return RemoteAssets.Messages.next();
			})
			.flatMap(item -> {
				check(item.done, "WS graceful end");
				return RemoteAssets.TypedMessages.next();
			})
			.flatMap(item -> {
				check(item.text && item.value.seq == 1, "WS typed text");
				return RemoteAssets.TypedMessages.next();
			})
			.flatMap(item -> {
				check(!item.text && item.value.seq == 2, "WS typed binary JSON");
				return RemoteAssets.TypedMessages.next();
			})
			.flatMap(item -> {
				check(item.done, "WS typed end");
				return RemoteAssets.SecureMessages.next();
			})
			.flatMap(item -> {
				check(item.value.seq == 1, "WSS typed first message");
				return RemoteAssets.SecureMessages.next();
			})
			.flatMap(item -> {
				check(item.value.seq == 2, "WSS typed second message");
				return RemoteAssets.SecureMessages.next();
			})
			.flatMap(item -> {
				check(item.done, "WSS end");
				return collect(RemoteAssets.Chunks, new BytesBuffer());
			})
			.flatMap(bytes -> {
				check(bytes.toHex() == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "HTTPS pull chunks");
				final idle = source.openStream(RemoteConfig.idle);
				return idle.next().flatMap(item -> {
					check(item.text, "idle welcome");
					final pending = idle.next();
					idle.close();
					return failure(pending);
				});
			})
			.flatMap(_ -> RemoteAssets.QueuedMessages.next())
			.flatMap(item -> {
				check(item.value.seq == 7, "queued message precedes transport error");
				return failure(RemoteAssets.QueuedMessages.next());
			})
			.flatMap(_ -> failure(source.openStream(RemoteConfig.oversize).next()))
			.flatMap(_ -> failure(source.read(RemoteConfig.missing)))
			.flatMap(_ -> {
				#if (!wasm && !emscripten)
				return failure(new RemoteSource({timeoutMs: 5000}).read(RemoteConfig.secure));
				#else
				return Future.resolved(Nothing);
				#end
			})
			.then(_ -> {
				RemoteAssets.unload();
				loader.close();
				Sys.println("PASS: remote URI values, HTTP chunks, WS/WSS frames and cancellation");
				hxn.Loop.exit(0);
			}, error -> {
				Sys.stderr().writeString(Std.string(error) + "\n");
				Sys.exit(1);
			});
	}
}

private typedef BytesBuffer = haxe.io.BytesBuffer;
