import hxn.Future;
import hxn.Unit;
import hxn.assets.KnowledgeGraph;
import hxn.file.Storage;
import hxn.file.StorageOptions;

class Main {
	static function main():Void {
		final options:StorageOptions = #if (!wasm && !emscripten && !hxn_file_mobile) {dataRoot: haxe.io.Path.join([haxe.io.Path.directory(Sys.programPath()), "graph-data"])} #else null #end;
		final expected:Null<Bool> = #if (hxn_assets_jit == "on") true #elseif (hxn_assets_jit == "off") false #else null #end;
		final result = #if (!wasm && !emscripten && !hxn_file_mobile) Sys.args().indexOf("--restore-only") >= 0 ? restore(options, expected) : #end
		EmbeddedGraphExample.run(options, expected);
		result.then(_ -> {
			Sys.println("PASS: embedded Haxe graph API and annotation scenario");
			hxn.Loop.exit(0);
		}, error -> {
			Sys.stderr().writeString(Std.string(error) + "\n");
			Sys.exit(1);
		});
	}

	public static function restore(options:StorageOptions, expected:Null<Bool>):Future<Unit> {
		final files = new Storage("org.hxn.knowledge.example", options);
		var graph:KnowledgeGraph = null;
		return KnowledgeGraph.load(files, "graph/checkpoint.json")
			.flatMap(value -> {
				graph = value;
				if (expected != null && graph.jit != expected)
					throw "wrong restored graph build";
				Sys.println("restored graph JIT: " + graph.jit);
				return graph.query("MATCH (npc:Npc) WHERE npc._hxn_deleted = false RETURN npc.id");
			})
			.flatMap(result -> {
				if (result.rows.length != 4)
					throw "cross-build checkpoint lost entities";
				return graph.close();
			})
			.map(_ -> {
				files.close();
				return Unit.Nothing;
			});
	}
}
