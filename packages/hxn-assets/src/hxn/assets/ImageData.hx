package hxn.assets;

import haxe.io.Bytes;

/** CPU image pixels: unpremultiplied RGBA8, rows top first, tightly packed. */
class ImageData {
	public final width:Int;
	public final height:Int;
	public final pixels:Bytes;

	public function new(width:Int, height:Int, pixels:Bytes) {
		if (width < 1 || height < 1 || pixels == null || width > 16777216.0 / height || pixels.length != width * height * 4)
			throw "invalid RGBA8 image dimensions or pixels";
		this.width = width;
		this.height = height;
		this.pixels = pixels;
	}
}
