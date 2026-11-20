#!/usr/bin/env python3
"""Check knowledge schemas and run the semantic/spatial example against KyuGraph."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hxn", type=Path, default=ROOT.parent / "hxn")
    parser.add_argument("--ash", default="ash")
    parser.add_argument("--adapter", action="store_true", help="run projection replay against the pinned embedded KyuGraph engine")
    parser.add_argument("--kyugraph", type=Path, help="run the adapter against this local KyuGraph checkout")
    args = parser.parse_args()
    common = ["haxe", "-cp", args.hxn / "haxe", "-cp", ROOT / "packages/hxn-assets/src", "-lib", "format:3.8.0"]

    def run(command, *, valid=True, timeout=120, cwd=ROOT):
        result = subprocess.run(list(map(str, command)), cwd=cwd, capture_output=True, text=True, timeout=timeout)
        output = result.stdout + result.stderr
        if (result.returncode == 0) != valid:
            raise AssertionError(output)
        return output

    (ROOT / "target").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="knowledge-check-", dir=ROOT / "target") as directory:
        work = Path(directory)
        cases = [
            ("", "@:identity var id:String;", "requires @:knowledge"),
            ('@:knowledge("Thing")', "var id:String;", "exactly one @:identity"),
            ('@:knowledge("Thing")', "@:identity var id:Int;", "non-null String"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:identity var other:String;", "exactly one @:identity"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:fact var data:Dynamic;", "scalar"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:relation(\"KNOWS\") var known:Array<String>;", "KnowledgeRef<T>"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:fact @:fact var value:String;", "duplicate :fact"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:fact(\"id\") var value:String;", "duplicate semantic"),
            ('@:knowledge("bad/type")', "@:identity var id:String;", "portable identifiers"),
            ('@:knowledge("Thing",0)', "@:identity var id:String;", "positive"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:spatial(\"missing\") var position:{x:Float,y:Float};", "required single @:relation"),
            ('@:knowledge("Thing")', "@:identity var id:String; @:fact var values:Array<Null<Int>>;", "scalar"),
        ]
        (work / "Main.hx").write_text('class Main { static function main() { var value:Data = cast null; hxn.assets.Knowledge.capture(value); } }')
        for metadata, fields, message in cases:
            (work / "Data.hx").write_text(metadata + "\ntypedef Data = {" + fields + "}")
            output = run([*common, "-cp", work, "-main", "Main", "--interp"], valid=False)
            assert message in output, (metadata,fields,output)
        print("PASS: knowledge schema and relation compile diagnostics", flush=True)

        (work / "Data.hx").write_text('@:knowledge("Data") typedef Data = {@:identity var id:String; @:fact var goal:String; var hidden:String;}')
        partial_cases = [
            ('["missing"]', "has no field missing"),
            ('["id"]', "always reads the identity"),
            ('["hidden"]', "has no knowledge annotation"),
            ('[]', "selects at least one field"),
            ('["goal", "goal"]', "names goal twice"),
            ('names', "array literal of field names"),
        ]
        for selection, message in partial_cases:
            (work / "Main.hx").write_text('class Main { static function main() { var names = ["goal"]; var value:Data = cast null; hxn.assets.Knowledge.captureFields(value, ' + selection + '); } }')
            output = run([*common, "-cp", work, "-main", "Main", "--interp"], valid=False)
            assert message in output, (selection, output)
        (work / "Main.hx").write_text('class Main { static function main() { var value:Data = cast null; hxn.assets.Knowledge.capture(value); } }')
        print("PASS: partial knowledge capture diagnostics", flush=True)

        # Repeated identities in one batch coalesce, and a partial merges into what precedes it.
        (work / "Data.hx").write_text('@:knowledge("Data") typedef Data = {@:identity var id:String; @:fact var goal:String; @:fact var mood:String;}')
        (work / "Main.hx").write_text('''import hxn.assets.Knowledge;
import hxn.assets.knowledge.KnowledgeBatch;
class Main { static function main() {
    final value:Data = {id: "a", goal: "g1", mood: "m1"};
    final complete = Knowledge.capture(value);
    value.goal = "g2";
    final goal = Knowledge.captureFields(value, ["goal"]);
    value.mood = "m2";
    final mood = Knowledge.captureFields(value, ["mood"]);
    var data = new KnowledgeBatch("n", "s", 1, [complete, goal]).data();
    if (data.version != 1 || data.nodes[0].fields != null || data.nodes[0].facts.goal != "g2" || data.nodes[0].facts.mood != "m1") throw "complete then partial";
    data = new KnowledgeBatch("n", "s", 1, [goal, mood]).data();
    if (data.version != 2 || data.nodes[0].fields.join(",") != "goal,mood" || data.nodes[0].facts.mood != "m2") throw "partial then partial";
    data = new KnowledgeBatch("n", "s", 1, [goal, complete]).data();
    if (data.version != 1 || data.nodes[0].facts.goal != "g1") throw "partial then complete";
    try { new KnowledgeBatch("n", "s", 1, [Knowledge.remove(value), goal]); throw "accepted"; } catch (e:String) { if (e == "accepted") throw "partial after tombstone"; }
    if (!goal.isPartial() || complete.isPartial()) throw "isPartial";
}}''')
        run([*common, "-cp", work, "-main", "Main", "--interp"])
        print("PASS: partial knowledge snapshots coalesce within a batch", flush=True)

        (work / "Data.hx").write_text('@:knowledge("Target") typedef Target = {var id:String;}\n@:knowledge("Data") typedef Data = {@:identity var id:String; @:relation("KNOWS") var target:hxn.assets.KnowledgeRef<Target>;}')
        output = run([*common,"-cp",work,"-main","Main","--interp"],valid=False)
        assert "exactly one @:identity" in output, output

        # A reused schema module must reflect metadata edits without a macro-side registry.
        (work / "Data.hx").write_text('@:knowledge("First") typedef Data = {@:identity var id:String;}')
        (work / "Main.hx").write_text('class Main { static function main() { final value:Data = {id:"one"}; Sys.println(hxn.assets.Knowledge.capture(value).data().schema.name); } }')
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            endpoint = "127.0.0.1:" + str(listener.getsockname()[1])
        server = subprocess.Popen(["haxe","--wait",endpoint],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    with socket.create_connection(("127.0.0.1",int(endpoint.split(":")[1])),timeout=.1):
                        break
                except OSError:
                    if time.monotonic() > deadline: raise AssertionError("compiler server did not start")
                    time.sleep(.05)
            for attempt,label in enumerate(("First","First","Second")):
                (work / "Data.hx").write_text('@:knowledge("'+label+'") typedef Data = {@:identity var id:String;}')
                stamp = time.time() + 2 + attempt * 2
                os.utime(work / "Data.hx",(stamp,stamp))
                output = run(["haxe","--connect",endpoint,*common[1:],"-cp",work,"-main","Main","--interp"])
                assert label in output, output
        finally:
            server.terminate(); server.communicate(timeout=10)
        print("PASS: knowledge metadata follows compilation-server schema edits",flush=True)

        example = [*common,"-cp",ROOT/"examples/knowledge","-D","hxn_assets_dir="+str(ROOT/"examples/knowledge/assets")]
        first = work/"eval.json"
        print(run([*example,"-D","hxn_knowledge_export","--run","KnowledgeExample",first]).strip(),flush=True)
        batches = json.loads(first.read_text())
        assert len(batches) == 8 and "Never exported" not in first.read_text()
        # Complete batches keep format version 1; partial ones carry only what they select.
        assert [batch["version"] for batch in batches] == [1, 1, 1, 1, 1, 2, 2, 1], [batch["version"] for batch in batches]
        goal, moved = batches[5]["nodes"][0], batches[6]["nodes"][0]
        assert goal["fields"] == ["goal"] and goal["facts"] == {"goal": "Study the seal"} and goal["bounds"] is None, goal
        assert goal["links"] == [[], []], goal
        assert moved["fields"] == ["IN_WORLD"] and moved["facts"] == {} and moved["bounds"]["minX"] == 1000, moved
        assert all("fields" not in node for batch in batches if batch["version"] == 1 for node in batch["nodes"])
        bytecode = work/"example.hl"
        run([*example,"-D","hxn_knowledge_export","-main","KnowledgeExample","-dce","full","-hl",bytecode])
        second = work/"ash.json"
        run([args.ash,bytecode,second])
        assert json.loads(second.read_text()) == batches, "knowledge values differ between eval and Ash/full-DCE"
        print("PASS: deterministic knowledge wire values in eval and Ash/full-DCE",flush=True)

        if args.adapter or args.kyugraph:
            adapter = ROOT/"adapters/kyugraph"
            manifest = adapter/"Cargo.toml"
            if args.kyugraph:
                manifest = work/"Cargo.toml"
                manifest.write_text('[package]\nname="hxn-knowledge-local-check"\nversion="0.0.0"\nedition="2024"\n[workspace]\n[dependencies]\nhxn-assets-kyugraph={path='+json.dumps(str(adapter))+'}\nkyu-graph={path='+json.dumps(str(args.kyugraph.resolve()/"crates/kyu-graph"))+',default-features=false,features=["jit"]}\nserde_json="1"\n[patch."https://github.com/offbit-ai/kyugraph.git"]\nkyu-graph={path='+json.dumps(str(args.kyugraph.resolve()/"crates/kyu-graph"))+'}\n')
                source = work/"src";source.mkdir()
                shutil.copy2(adapter/"examples/replay.rs",source/"main.rs")
            command = ["cargo","run","--manifest-path",manifest,"--target-dir",ROOT/"target/knowledge-kyugraph","--config",'build.rustflags=["-C", "symbol-mangling-version=v0"]']
            if not args.kyugraph: command += ["--locked","--example","replay"]
            output = run([*command,"--",first,work/"database"],timeout=1200)
            assert "PASS: KyuGraph" in output, output
            print(output[output.index("revision 1:"):].strip(),flush=True)


if __name__ == "__main__":
    main()
