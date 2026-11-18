package hxn.assets;

import haxe.io.Bytes;

/** Built-in value decoders used by generated dynamic-asset loaders. */
@:noCompletion
class AssetDecode {
	/** Decodes JSON and validates the generated expected-type description. */
	public static function json(bytes:Bytes, shape:Dynamic):Dynamic {
		final value = haxe.Json.parse(bytes.toString());
		validate(value, shape, "asset");
		return value;
	}

	static function validate(value:Dynamic, shape:Dynamic, path:String):Void {
		if (shape == null || shape.kind == "any")
			return;
		if (shape.kind == "nullable") {
			if (value != null)
				validate(value, shape.value, path);
			return;
		}
		var valid = switch (shape.kind) {
			case "string": Std.isOfType(value, String);
			case "int": Std.isOfType(value, Int);
			case "float": Std.isOfType(value, Float);
			case "bool": Std.isOfType(value, Bool);
			case "array": Std.isOfType(value, Array);
			case "object": value != null && Type.typeof(value) == TObject;
			case _: false;
		};
		if (!valid)
			throw 'wrong asset value type at $path: expected ${shape.kind}';
		if (shape.kind == "array") {
			final array:Array<Dynamic> = cast value;
			for (i in 0...array.length)
				validate(array[i], shape.value, '$path[$i]');
		}
		if (shape.kind == "object")
			for (field in (shape.fields : Array<Dynamic>)) {
				if (!Reflect.hasField(value, field.name)) {
					if (!field.optional)
						throw 'missing asset field $path.${field.name}';
				} else
					validate(Reflect.field(value, field.name), field.value, '$path.${field.name}');
			}
	}

	/** Decodes PNG to portable RGBA8 pixels; no graphics device is created. */
	public static function png(bytes:Bytes):ImageData {
		if (bytes.length < 20)
			throw "truncated PNG";
		var offset = 8, complete = false;
		while (offset <= bytes.length - 12) {
			final length = (bytes.get(offset) << 24) | (bytes.get(offset + 1) << 16) | (bytes.get(offset + 2) << 8) | bytes.get(offset + 3);
			if (length < 0 || length > bytes.length - offset - 12)
				throw "invalid PNG chunk length";
			final kind = bytes.getString(offset + 4, 4);
			if (kind == "IHDR" && length != 13)
				throw "invalid PNG header length";
			offset += length + 12;
			if (kind == "IEND") {
				if (length != 0)
					throw "invalid PNG end chunk";
				complete = true;
				break;
			}
		}
		if (!complete || offset != bytes.length)
			throw "invalid PNG chunk sequence";
		final data = new format.png.Reader(new haxe.io.BytesInput(bytes)).read();
		var header:Null<format.png.Data.Header> = null,
			palette:Null<Bytes> = null,
			alpha:Null<Bytes> = null;
		final compressed = new haxe.io.BytesBuffer();
		for (chunk in data)
			switch (chunk) {
				case CHeader(value):
					if (header != null)
						throw "duplicate PNG header";
					header = value;
				case CPalette(value):
					if (palette != null)
						throw "duplicate PNG palette";
					palette = value;
				case CUnknown("tRNS", value):
					if (alpha != null)
						throw "duplicate PNG transparency";
					alpha = value;
				case CData(value):
					compressed.add(value);
				case _:
			}
		if (header == null || header.width < 1 || header.height < 1 || header.width > 16777216.0 / header.height)
			throw "decoded image exceeds the 64 MiB pixel limit";
		if (header.interlaced)
			throw "interlaced PNG requires an application decoder";
		final channels = switch (header.color) {
			case ColGrey(a): a ? 2 : 1;
			case ColTrue(a): a ? 4 : 3;
			case ColIndexed: 1;
		};
		final indexed = switch (header.color) {
			case ColIndexed: true;
			case _: false;
		};
		if (indexed) {
			if ([1, 2, 4, 8].indexOf(header.colbits) < 0
				|| palette == null
				|| palette.length == 0
				|| palette.length % 3 != 0
				|| palette.length > 3 * (1 << header.colbits))
				throw "invalid indexed PNG palette or bit depth";
			if (alpha != null && alpha.length > Std.int(palette.length / 3))
				throw "invalid PNG transparency palette";
		} else {
			if (header.colbits != 8)
				throw "PNG decoder supports 8-bit RGB and grayscale samples";
			if (alpha != null && alpha.length != (channels == 1 ? 2 : channels == 3 ? 6 : 0))
				throw "invalid PNG transparency";
		}
		final row = Math.ceil(header.width * channels * header.colbits / 8) + 1, expected = row * 1.0 * header.height;
		if (expected > 83886080)
			throw "PNG scanlines exceed the decode budget";
		final input = compressed.getBytes(), raw = Bytes.alloc(Std.int(expected) + 1);
		final inflater = new haxe.zip.Uncompress();
		var read = 0, written = 0, done = false;
		try {
			while (!done && written < raw.length) {
				final step = inflater.execute(input, read, raw, written);
				read += step.read;
				written += step.write;
				done = step.done;
				if (!done && step.read == 0 && step.write == 0)
					throw "invalid PNG compressed data";
			}
			if (!done || written != Std.int(expected))
				throw "PNG scanline data does not match its dimensions";
		} catch (error:Dynamic) {
			inflater.close();
			throw error;
		}
		inflater.close();
		final stepBytes = indexed ? 1 : channels;
		for (y in 0...header.height) {
			final start = y * row, filter = raw.get(start);
			if (filter > 4)
				throw "invalid PNG filter";
			for (x in 0...row - 1) {
				final at = start + 1 + x, left = x >= stepBytes ? raw.get(at - stepBytes) : 0, above = y > 0 ? raw.get(at - row) : 0;
				final upperLeft = y > 0 && x >= stepBytes ? raw.get(at - row - stepBytes) : 0;
				final prediction = switch (filter) {
					case 0: 0;
					case 1: left;
					case 2: above;
					case 3: (left + above) >> 1;
					case _: paeth(left, above, upperLeft);
				};
				raw.set(at, (raw.get(at) + prediction) & 255);
			}
		}
		final pixels = Bytes.alloc(header.width * header.height * 4);
		var into = 0;
		for (y in 0...header.height)
			for (x in 0...header.width) {
				final at = y * row + 1 + x * channels;
				var r:Int, g:Int, b:Int, a = 255;
				switch (header.color) {
					case ColIndexed:
						final bit = x * header.colbits, index = (raw.get(y * row + 1 + (bit >> 3)) >> (8 - header.colbits - (bit & 7))) & ((1 << header.colbits)
							- 1);
						if (index >= Std.int(palette.length / 3))
							throw "PNG palette index is out of range";
						r = palette.get(index * 3);
						g = palette.get(index * 3 + 1);
						b = palette.get(index * 3 + 2);
						if (alpha != null && index < alpha.length)
							a = alpha.get(index);
					case ColGrey(hasAlpha):
						r = g = b = raw.get(at);
						if (hasAlpha)
							a = raw.get(at + 1);
						else if (alpha != null && alpha.get(0) == 0 && alpha.get(1) == r)
							a = 0;
					case ColTrue(hasAlpha):
						r = raw.get(at);
						g = raw.get(at + 1);
						b = raw.get(at + 2);
						if (hasAlpha)
							a = raw.get(at + 3);
						else if (alpha != null && alpha.get(0) == 0 && alpha.get(1) == r && alpha.get(2) == 0 && alpha.get(3) == g && alpha.get(4) == 0
							&& alpha.get(5) == b)
							a = 0;
				}
				pixels.set(into++, r);
				pixels.set(into++, g);
				pixels.set(into++, b);
				pixels.set(into++, a);
			}
		return new ImageData(header.width, header.height, pixels);
	}

	static function paeth(left:Int, above:Int, upperLeft:Int):Int {
		final value = left + above - upperLeft;
		final a = Std.int(Math.abs(value - left)), b = Std.int(Math.abs(value - above)), c = Std.int(Math.abs(value - upperLeft));
		return a <= b && a <= c ? left : b <= c ? above : upperLeft;
	}
}
