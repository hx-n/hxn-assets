package hxn.assets;

import haxe.io.Bytes;
import haxe.Exception;
import hxn.Future;

/** A pull stream of decoded messages or chunks, with one pending read at a time. */
class AssetStream<T> {
	var state:StreamState;
	final decode:Bytes->T;

	public function new(driver:AssetStreamDriver, decode:Bytes->T) {
		if (driver == null || decode == null)
			throw "asset stream requires a driver and decoder";
		state = new StreamState(driver);
		this.decode = decode;
	}

	/** Mapped views share the same connection; closing one closes them all. */
	public function map<U>(convert:T->U):AssetStream<U> {
		final view = new AssetStream<U>(state.driver, bytes -> convert(decode(bytes)));
		view.state = state;
		return view;
	}

	public function next():Future<StreamItem<T>> {
		final current = state;
		if (current.ended)
			return Future.resolved({done: true, value: null, text: false});
		if (current.closed)
			return Future.rejected(new Exception("asset stream is closed"));
		if (current.busy)
			return Future.rejected(new Exception("only one asset stream reader may be pending"));
		current.busy = true;
		var pending:Future<StreamItem<Bytes>>;
		try {
			pending = current.driver.next();
		} catch (error:Dynamic) {
			current.busy = false;
			finish(false);
			return Future.rejected(new Exception(Std.string(error)));
		}
		return pending.map(item -> {
			current.busy = false;
			if (current.closed)
				throw "asset stream is closed";
			if (item.done) {
				current.ended = true;
				finish(false);
				return {done: true, value: null, text: false};
			}
			return {done: false, value: decode(item.value), text: item.text};
		}).recover(error -> {
			current.busy = false;
			finish(false);
			throw error;
		});
	}

	/** Continuously pulls after each synchronous handler returns; returns a cancellation function. */
	public function listen(onItem:T->Void, ?onEnd:Void->Void, ?onError:Exception->Void):Void->Void {
		var stopped = false, pumping = false, again = false;
		var pull:Void->Void = null;
		pull = () -> {
			if (stopped)
				return;
			if (pumping) {
				again = true;
				return;
			}
			pumping = true;
			try {
				do {
					again = false;
					next().then(item -> {
						if (stopped)
							return;
						if (item.done) {
							stopped = true;
							if (onEnd != null)
								onEnd();
							return;
						}
						try {
							onItem(item.value);
						} catch (error:Exception) {
							stopped = true;
							finish(false);
							if (onError != null)
								onError(error);
							else
								throw error;
							return;
						}
						pull();
					}, error -> {
						if (!stopped) {
							stopped = true;
							if (state.cancelled) {
								if (onEnd != null)
									onEnd();
							} else if (onError != null)
								onError(error);
							else
								throw error;
						}
					});
				} while (again && !stopped);
			} catch (error:Dynamic) {
				pumping = false;
				throw error;
			}
			pumping = false;
		};
		pull();
		return () -> {
			stopped = true;
			close();
		};
	}

	/** Cancels pending reads; listeners finish normally on an explicit close. */
	public function close():Void
		finish(true);

	function finish(cancelled:Bool):Void {
		if (cancelled)
			state.cancelled = true;
		if (!state.closed) {
			state.closed = true;
			state.driver.close();
		}
	}
}

private class StreamState {
	public final driver:AssetStreamDriver;
	public var busy = false;
	public var closed = false;
	public var cancelled = false;
	public var ended = false;

	public function new(driver:AssetStreamDriver) {
		this.driver = driver;
	}
}
