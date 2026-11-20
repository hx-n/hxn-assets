import haxe.io.Bytes;
import hxn.assets.*;
import hxn.file.Storage;

#if (android && cpp)
@:buildXml('<include name="${hxn_mobile_xml}"/>')
#end
class MobileCheck {
	static function require(value:Bool, message:String):Void {
		if (!value)
			throw message;
	}

	static function main():Void {
		Sys.println("START: mobile suite=" + Sys.getEnv("HXN_ASSET_SUITE"));
		if (Sys.getEnv("HXN_ASSET_SUITE") == "remote") {
			@:privateAccess RemoteCheck.main();
			return;
		}
		#if hxn_graph_check
		final nonce = haxe.Resource.getString("mobile-nonce");
		final marker = new Storage("org.hxn.knowledge.example");
		final expectedJit = #if (hxn_assets_jit == "on") true #else false #end;
		var phase = "";
		marker.getPreference("graph-nonce")
			.flatMap(previous -> {
				phase = previous.found ? "reopen" : "write";
				if (previous.found && previous.value != nonce)
					throw "graph app retained another test's data";
				return previous.found ? Main.restore(null, expectedJit) : EmbeddedGraphExample.run(null, expectedJit);
			})
			.flatMap(_ -> marker.setPreference("graph-nonce", nonce))
			.then(_ -> {
				marker.close();
				Sys.println("PASS: mobile graph " + phase + " " + nonce);
				#if !hxn_mobile_android
				hxn.Loop.exit(0);
				#end
			}, error -> {
				Sys.stderr().writeString(Std.string(error) + "\n");
				hxn.Loop.exit(1);
			});
		return;
		#end
		hxn.Log.level = Debug;
		final records:Array<hxn.LogRecord> = [];
		hxn.Log.sink = record -> records.push(record);
		TypedCheck.runChecks();
		final expected = haxe.Resource.getString("mobile-nonce");
		final files = new Storage("dev.hxn.assets.mobile");
		final loader = new AssetLoader(new FileSource(files), MobileAssets.catalog());
		var phase = "";
		MobileAssets.load(loader).flatMap(_ -> {
			require(MobileAssets.Nonce == expected, "bundle/APK nonce");
			require(MobileAssets.Level.name == "start" && MobileAssets.Level.spawn.x == 1.5, "runtime typed JSON");
			require(MobileAssets.Image.pixels.toHex() == "ff0000ff00ff0080", "runtime PNG pixels");
			return files.getPreference("generation");
		}).flatMap(previous -> {
			if (!previous.found) {
				phase = "write";
				return files.writeSave("slot/check.bin", Bytes.ofString("save-" + expected))
					.flatMap(_ -> files.setPreference("unicode", "héllo 🎨"))
					.flatMap(_ -> files.setPreference("generation", expected));
			}
			phase = "reopen";
			require(previous.value == expected, "persisted generation");
			return files.readSave("slot/check.bin").flatMap(bytes -> {
				require(bytes.toString() == "save-" + expected, "save survived app restart");
				return files.getPreference("unicode");
			}).map(value -> {
				require(value.found && value.value == "héllo 🎨", "preference survived app restart");
				return hxn.Unit.Nothing;
			});
		}).then(_ -> {
			hxn.Log.flush();
			require(records.filter(r -> r.target == "hxn.file" && r.origin == "rust").length > 0, "native shared logs");
			require(records.filter(r -> r.target == "hxn.assets" && r.origin == "haxe").length > 0, "frontend shared logs");
			loader.close();
			files.close();
			Sys.println("PASS: mobile assets " + phase + " " + expected);
			#if !hxn_mobile_android
			hxn.Loop.exit(0);
			#end
		}, error -> {
			Sys.stderr().writeString(Std.string(error) + "\n");
			hxn.Loop.exit(1);
		});
	}
}

@:build(hxn.assets.Assets.build())
@:contentAddressed
private class MobileAssets {
	@:asset("mobile.level", "levels/start.json") @:dynamicAsset public static var Level:{
		name:String,
		lives:Int,
		spawn:{x:Float, y:Float},
		tags:Array<String>
	};
	@:asset("mobile.image", "pixels.png") @:dynamicAsset public static var Image:ImageData;
	@:asset("mobile.nonce", "test-run.txt") @:dynamicAsset public static var Nonce:String;
}
