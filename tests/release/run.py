#!/usr/bin/env python3
"""Compile and run consumers using installed ZIPs, without source bindings."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("native", "wasm", "emcc", "emcc-threads"))
    parser.add_argument("--ash", default="ash")
    parser.add_argument("--chrome", default="google-chrome")
    parser.add_argument("--hxn", type=Path, default=ROOT / "tests/.tools/hxn")
    args = parser.parse_args()
    out = ROOT / "target/release-consumer" / args.mode
    out.mkdir(parents=True, exist_ok=True)

    def run(argv, timeout=600, cwd=ROOT):
        subprocess.run(list(map(str, argv)), cwd=cwd, timeout=timeout, check=True)

    for name in ("hxn-file", "hxn-assets"):
        archives = list((ROOT / "target/release-dist").glob(name + "-*.zip"))
        assert len(archives) == 1, archives
        run(["haxelib", "install", archives[0], "--always", "--quiet", "--skip-dependencies"])
    run(["hxn", "plugins"])
    run(["hxn", "assets", "catalog", "--source", ROOT / "tests/fixtures/assets", "--out", out / "catalog.json", "--content-addressed"])
    run(["hxn", "assets", "stage", "--source", ROOT / "tests/fixtures/assets", "--out", out / "staged", "--content-addressed"])
    assert (out / "catalog.json").is_file() and (out / "staged/.hxn-assets.json").is_file()
    common = ["haxe", "-lib", "hxn-assets", "-cp", ROOT / "tests/assets", "-cp", ROOT / "examples/knowledge",
              "-D", "hxn_assets_dir=" + str(ROOT / "tests/fixtures/assets"), "-main", "FilesCheck"]
    if args.mode in ("native", "wasm"):
        bytecode = out / "main.hl"
        flags = ["-D", "wasm", "-D", "hxn_threads"] if args.mode == "wasm" else []
        run([*common, *flags, "-hl", bytecode])
        if args.mode == "native":
            for mode in ([], ["--mode", "jit"], ["--mode", "interp"]):
                run([args.ash, *mode, bytecode, out / "assets", out / "data-hl"], timeout=120)
        else:
            native = out / "libfile.a"
            run([args.ash, "--build", out / "main.wasm", "--target", "wasm32-wasip1-threads", "--native-lib", native, bytecode])
            run(["node", args.hxn / "crates/hxn-cli/src/ash_page.mjs", args.ash, out, args.chrome], timeout=180)
    if args.mode != "wasm":
        target = out / "cpp"
        flags = []
        if args.mode.startswith("emcc"):
            flags = ["-D", "emscripten", "-D", "wasm", "-D", "HXCPP_LINK_EMSCRIPTEN_EXT=.html", "-D", "HXCPP_LINK_EMRUN", "-D", "HXCPP_LINK_MEMORY_GROWTH"]
            if args.mode == "emcc-threads":
                flags += ["-D", "hxn_threads"]
        run([*common, *flags, "-cpp", target])
        if args.mode == "native":
            run([target / ("FilesCheck.exe" if os.name == "nt" else "FilesCheck"), target / "assets", out / "data-cpp"], timeout=120)
        else:
            stdout, stderr = out / "stdout.txt", out / "stderr.txt"
            with tempfile.TemporaryDirectory(prefix="hxn-release-browser-", ignore_cleanup_errors=True) as profile:
                run(["emrun", "--browser", args.chrome, "--browser_args=--headless=new --no-first-run --no-default-browser-check --user-data-dir=" + profile,
                     "--kill_exit", "--timeout", "120", "--timeout-returncode", "1", "--log-stdout", stdout, "--log-stderr", stderr, target / "FilesCheck.html"], timeout=180)
            assert "PASS: annotated assets" in stdout.read_text() + stderr.read_text()
    print("PASS: installed packages, CLI plugin, knowledge, files and persistence on " + args.mode, flush=True)


if __name__ == "__main__":
    main()
