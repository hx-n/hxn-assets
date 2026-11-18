#!/usr/bin/env python3
"""Exercise annotations, compile errors, staging and compiler-server invalidation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import struct
import zlib
import time

ROOT = Path(__file__).resolve().parents[2]


def run(argv, *, cwd=ROOT, success=True):
    result = subprocess.run([str(value) for value in argv], cwd=cwd, capture_output=True, text=True, timeout=120)
    output = result.stdout + result.stderr
    if success and result.returncode:
        raise AssertionError(output)
    if not success and not result.returncode:
        raise AssertionError("invalid asset declarations compiled successfully")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hxn", type=Path, default=ROOT.parent / "hxn")
    parser.add_argument("--ash", default="ash")
    options = parser.parse_args()
    common = ["haxe", "-lib", "format:3.8.0", "-cp", options.hxn / "haxe", "-cp", ROOT / "packages/hxn-assets/src"]
    output = run([*common, "-cp", ROOT / "tests/assets", "-D", "hxn_assets_dir=" + str(ROOT / "tests/fixtures/assets"),
                  "-main", "AssetsCheck", "--interp"])
    assert "PASS:" in output, output
    print(output.strip(), flush=True)
    output = run([*common, "-cp", ROOT / "tests/assets", "-D", "hxn_assets_dir=" + str(ROOT / "tests/fixtures/assets"),
                  "-main", "TypedCheck", "--interp"])
    assert "PASS:" in output, output
    print(output.strip(), flush=True)
    output = run([*common, "-cp", ROOT / "tests/assets", "-D", "hxn_assets_dir=" + str(ROOT / "tests/fixtures/assets"),
                  "-main", "StreamCheck", "--interp"])
    assert "PASS:" in output, output
    print(output.strip(), flush=True)
    (ROOT / "target").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="asset annotations ", dir=ROOT / "target") as temporary:
        directory = Path(temporary)
        source = directory / "source assets"
        source.mkdir()
        (source / "payload").write_text("same")
        (source / "other").write_text("same")
        (source / "unused").write_text("not selected")
        (source / "level.json").write_text('{"name":"start","lives":3}')
        (source / "bad.png").write_bytes(b"not a PNG")
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        signature = b"\x89PNG\r\n\x1a\n"
        (source / "chunk.png").write_bytes(signature + struct.pack(">I", 0x7fffffff) + b"IDAT" + bytes(4))
        for name, pixels in [("short.png", bytes([0])), ("extra.png", bytes([0, 0, 0])), ("index.png", bytes([0, 1]))]:
            image = signature + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 3, 0, 0, 0))
            image += chunk(b"PLTE", bytes([255, 0, 0])) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
            (source / name).write_bytes(image)
        (directory / "Main.hx").write_text('class Main { static function main() { Sys.println(Declared.catalog().toJson()); } }')
        arguments = [*common, "-cp", directory, "-D", "hxn_assets_dir=" + str(source), "-main", "Main"]

        def declaration(fields, metadata=""):
            (directory / "Declared.hx").write_text(metadata + "\n@:build(hxn.assets.Assets.build())\nclass Declared {\n" + fields + "\n}\n")

        cases = [
            ('@:asset("same", "payload") public static var A:String; @:asset("same", "other") public static var B:String;', "duplicate asset address"),
            ('@:asset("absent") public static var A:String;', "asset file does not exist"),
            ('@:asset("../outside") public static var A:String;', "portable relative path"),
            ('@:asset("/payload") public static var A:String;', "portable relative path"),
            ('@:asset("payload") @:contentAddressed("md5") public static var A:String;', "supports only sha256"),
            ('@:asset("payload") @:assetDependsOn(Missing) public static var A:String;', "unknown asset field"),
            ('@:asset("payload") @:assetDependsOn(B) public static var A:String; @:asset("other") @:assetDependsOn(A) public static var B:String;', "dependency cycle"),
            ('@:asset("payload") public var A:String;', "static field"),
            ('@:asset("payload") public static var A:Int;', "cannot decode embedded asset"),
            ('@:asset("payload") public static var A:String = "manual";', "must not have an initializer"),
            ('@:asset("payload") @:asset("other") public static var A:String;', "duplicate :asset"),
            ('@:contentAddressed public static var A:String;', "requires an @:asset field"),
            ('@:asset("payload") public static var catalog:String;', "reserved"),
            ('@:asset("payload") public static var A:String; public static function catalog() {}', "reserved"),
        ]
        cases += [
            ('@:asset("level.json") public static var A:{name:Int, lives:Int};', "String should be Int"),
            ('@:asset("bad.png") public static var A:hxn.assets.ImageData;', "cannot decode embedded asset"),
            ('@:asset("unknown.payload") public static var A;', "cannot infer"),
            ('@:asset("runtime/value") @:dynamicAsset @:assetDecode(Declared.bad) public static var A:Int; public static function bad(bytes:haxe.io.Bytes):String { return "wrong"; }', "String should be Int"),
        ]
        cases += [
            ('@:asset("https://example.invalid/a.json") public static var A:Dynamic;', "require @:dynamicAsset"),
            ('@:asset("wss://example.invalid/a") @:dynamicAsset public static var A:Dynamic;', "require AssetStream<T>"),
            ('@:asset("https://example.invalid/a") @:dynamicAsset public static var A:hxn.assets.AssetStream<{n:Int}>;', "HTTP streams are byte chunks"),
            ('@:asset("wss://example.invalid/a") @:dynamicAsset @:contentAddressed public static var A:hxn.assets.AssetStream<haxe.io.Bytes>;', "unbounded stream"),
            ('@:asset("ftp://example.invalid/a") @:dynamicAsset public static var A:Dynamic;', "HTTP(S) or WS(S)"),
        ]
        for name in ("chunk.png", "short.png", "extra.png", "index.png"):
            cases.append(('@:asset("' + name + '") public static var A:hxn.assets.ImageData;', "cannot decode embedded asset"))
        for fields, message in cases:
            declaration(fields)
            failure = run([*arguments, "--interp"], success=False)
            assert message in failure, failure
            assert "Declared.hx:" in failure, failure
        outside = directory / "outside"
        outside.write_text("outside")
        sibling = directory / "source assets sibling"
        sibling.mkdir()
        (sibling / "payload").write_text("outside with a shared directory prefix")
        for target in (outside, sibling / "payload"):
            (source / "escape").symlink_to(target)
            declaration('@:asset("escape") public static var A:String;')
            failure = run([*arguments, "--interp"], success=False)
            assert "symlink escapes" in failure, failure
            (source / "escape").unlink()
        print("PASS: compile-time declaration, dependency and path diagnostics", flush=True)

        declaration('''@:asset("one", "payload") @:contentAddressed public static var One:haxe.io.Bytes;
            @:asset("two", "other") @:contentAddressed("sha256") @:assetDependsOn(One)
            @:assetLabels("visible") @:assetGroup("world") public static var Two:String;''')
        destination = directory / "out"
        destination.mkdir()
        bytecode = destination / "main.hl"
        compile_args = [*arguments, "--macro", "hxn.assets.Build.register()", "-hl", bytecode]
        run(compile_args)
        manifest_file = destination / "assets/.hxn-assets.json"
        manifest = json.loads(manifest_file.read_text())
        assert [asset["address"] for asset in manifest["assets"]] == ["one", "two"], manifest
        assert manifest["assets"][1]["dependencies"] == ["one"], manifest
        assert manifest["assets"][1]["labels"] == ["visible"], manifest
        assert manifest["assets"][1]["group"] == "world", manifest
        digest = "sha256:" + hashlib.sha256(b"same").hexdigest()
        assert all(asset["contentId"] == digest for asset in manifest["assets"]), manifest
        assert not (destination / "assets/unused").exists()
        runtime = run([options.ash, bytecode])
        assert json.loads(next(line for line in runtime.splitlines() if line.startswith("{"))) == manifest, runtime
        print("PASS: generated runtime catalog and staged manifest agree", flush=True)

        original_main = (directory / "Main.hx").read_text()
        (directory / "Main.hx").write_text('class Main { static function main() { Sys.println(Declared.addresses.One); } }')
        shutil.rmtree(destination / "assets")
        run([*compile_args, "-dce", "full"])
        assert json.loads(manifest_file.read_text()) == manifest, "inlined addresses lost their declarations during DCE"
        (directory / "Main.hx").write_text(original_main)
        print("PASS: declarations survive address inlining and dead-code elimination", flush=True)

        (directory / "Main.hx").write_text('class Main { static function main() { Sys.println(haxe.Json.stringify({catalog:Declared.catalog().toJson(), embedded:Declared.One.toHex()})); } }')
        # A reused module must retain its declarations/resources, and asset edits must invalidate it.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            endpoint = "127.0.0.1:" + str(listener.getsockname()[1])
        server = subprocess.Popen(["haxe", "--wait", endpoint], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while True:
                result = subprocess.run(["haxe", "--connect", endpoint, "--version"], capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    break
                if time.monotonic() > deadline:
                    raise AssertionError("compiler server did not start")
                time.sleep(0.05)
            for attempt in range(3):
                if attempt == 2:
                    (source / "payload").write_text("updated bytes")
                    stamp = time.time() + 2
                    os.utime(source / "payload", (stamp, stamp))
                shutil.rmtree(destination / "assets")
                run(["haxe", "--connect", endpoint, *compile_args[1:]])
                current = json.loads(manifest_file.read_text())
                expected = "sha256:" + hashlib.sha256((source / "payload").read_bytes()).hexdigest()
                assert current["assets"][0]["contentId"] == expected, current
                assert (destination / "assets/payload").read_bytes() == (source / "payload").read_bytes()
                runtime = run([options.ash, bytecode])
                decoded = json.loads(next(line for line in runtime.splitlines() if line.startswith("{")))
                assert json.loads(decoded["catalog"]) == current, runtime
                assert decoded["embedded"] == (source / "payload").read_bytes().hex(), runtime
        finally:
            server.terminate()
            server.communicate(timeout=10)
        print("PASS: compiler-server reuse and edited asset invalidation", flush=True)


if __name__ == "__main__":
    main()
