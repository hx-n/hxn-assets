import haxe.io.Bytes;
import hxn.file.Storage;

class Main {
	static function main() {
		final files = new Storage("org.hxn.storage.check");
		files.readAsset("nested/hello.txt")
			.flatMap(bytes -> {
				if (bytes.toString() != "bundled hello\n")
					throw "wrong bundled asset";
				return files.writeSave("slots/one.bin", Bytes.ofHex("0001ff0009"));
			})
			.flatMap(_ -> files.readSave("slots/one.bin"))
			.flatMap(bytes -> {
				if (bytes.toHex() != "0001ff0009")
					throw "wrong saved bytes";
				return files.setPreference("greeting", "héllo 🎨");
			})
			.flatMap(_ -> files.getPreference("greeting"))
			.then(value -> {
				if (!value.found || value.value != "héllo 🎨")
					throw "wrong preference";
				files.close();
				Sys.println("PASS: bundled file, save and preference");
				hxn.Loop.exit(0);
			}, error -> {
				Sys.stderr().writeString(Std.string(error) + "\n");
				Sys.exit(1);
			});
	}
}
