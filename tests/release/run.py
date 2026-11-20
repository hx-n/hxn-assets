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
    parser.add_argument("--cli", default="hxn")
    parser.add_argument("--installed", action="store_true", help="use an already isolated installed package set")
    parser.add_argument("--only-graph", action="store_true")
    parser.add_argument("--variant", choices=("both", "scalar", "jit"), default="both")
    args = parser.parse_args()
    out = ROOT / "target/release-consumer" / args.mode
    out.mkdir(parents=True, exist_ok=True)

    environment = os.environ.copy()
    if args.mode.startswith("emcc"):
        environment.pop("CC", None)
        environment.pop("CXX", None)
    def run(argv, timeout=600, cwd=ROOT):
        print("RUN:", *map(str, argv), flush=True)
        subprocess.run(list(map(str, argv)), cwd=cwd, env=environment, timeout=timeout, check=True)

    for name in (() if args.installed else ("hxn-file", "hxn-assets")):
        archives = list((ROOT / "target/release-dist").glob(name + "-*.zip"))
        assert len(archives) == 1, archives
        run(["haxelib", "install", archives[0], "--always", "--quiet", "--skip-dependencies"])
    run([args.cli, "plugins"])
    run([args.cli, "assets", "catalog", "--source", ROOT / "tests/fixtures/assets", "--out", out / "catalog.json", "--content-addressed"])
    run([args.cli, "assets", "stage", "--source", ROOT / "tests/fixtures/assets", "--out", out / "staged", "--content-addressed"])
    assert (out / "catalog.json").is_file() and (out / "staged/.hxn-assets.json").is_file()
    environment["RUSTUP_TOOLCHAIN"] = "hxn-consumer-must-not-build-rust"
    if args.only_graph:
        graph_checks(args, out / "graph", run, environment)
        return
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
    graph_checks(args, out / "graph", run, environment)
    print("PASS: installed packages, CLI plugin, knowledge, files and persistence on " + args.mode, flush=True)


def graph_checks(args, out, run, environment):
    out.mkdir(parents=True, exist_ok=True)
    native = args.mode == "native"
    variants = ("scalar", "jit") if native and args.variant == "both" else (args.variant if native and args.variant != "both" else "scalar",)
    common = [args.cli, "assets", "build", "-cp", ROOT / "tests/knowledge-native", "-cp", ROOT / "examples/knowledge",
              "-D", "hxn_assets_dir=" + str(ROOT / "examples/knowledge/assets"), "-main", "Main"]
    for variant in variants:
        flag = "--jit" if variant == "jit" else "--no-jit"
        if native or args.mode == "wasm":
            flags = [] if native else ["-D", "wasm", "-D", "hxn_threads"]
            bytecode = out / (variant + ".hl")
            run([*common, flag, *flags, "-hl", bytecode])
            if native:
                for repeat in range(2):
                    for mode in ([], ["--mode", "jit"], ["--mode", "interp"]):
                        run([args.ash, *mode, bytecode], timeout=120)
            else:
                # Both installed archives are inputs; no source build takes place.
                run([args.ash, "--build", out / "main.wasm", "--target", "wasm32-wasip1-threads",
                     "--native-lib", out / "libfile.a", "--native-lib", out / "libassets.a", bytecode])
                run(["node", args.hxn / "crates/hxn-cli/src/ash_page.mjs", args.ash, out, args.chrome], timeout=180)
        if args.mode != "wasm":
            target = out / ("cpp-" + variant)
            flags = []
            if not native:
                flags = ["-D", "emscripten", "-D", "wasm", "-D", "HXCPP_LINK_EMSCRIPTEN_EXT=.html", "-D", "HXCPP_LINK_EMRUN", "-D", "HXCPP_LINK_MEMORY_GROWTH"]
                if args.mode == "emcc-threads":
                    flags += ["-D", "hxn_threads"]
            run([*common, flag, *flags, "-cpp", target])
            if native:
                run([target / ("Main.exe" if os.name == "nt" else "Main")], timeout=120)
                host = out / ("host-" + variant)
                run([args.cli, "assets", "build", flag, "-cp", ROOT / "tests/release", "-main", "Host", "-D", "hxn_assets_dir=" + str(ROOT / "examples/knowledge/assets"), "-D", "scriptable", "-dce", "no", "-cpp", host], cwd=out)
                script = out / (variant + ".cppia")
                run([*common, flag, "-cppia", script])
                run([host / ("Host.exe" if os.name == "nt" else "Host"), script], timeout=120)
            else:
                stdout, stderr = out / "stdout.txt", out / "stderr.txt"
                stdout.unlink(missing_ok=True); stderr.unlink(missing_ok=True)
                with tempfile.TemporaryDirectory(prefix="hxn-graph-browser-", ignore_cleanup_errors=True) as profile:
                    run(["emrun", "--browser", args.chrome,
                         "--browser_args=--headless=new --no-first-run --no-default-browser-check --user-data-dir=" + profile,
                         "--kill_exit", "--timeout", "120", "--timeout-returncode", "1", "--log-stdout", stdout, "--log-stderr", stderr,
                         target / "Main.html"], timeout=180)
                assert "PASS: embedded Haxe graph API" in stdout.read_text() + stderr.read_text()
    if native and len(variants) == 2:
        # Each build reads a checkpoint written by the other implementation.
        for writer, reader in (("scalar", "jit"), ("jit", "scalar")):
            run([args.ash, out / (writer + ".hl")], timeout=120)
            run([args.ash, out / (reader + ".hl"), "--restore-only"], timeout=120)
    if not native:
        flags = ["-D", "wasm", "-D", "hxn_threads", "-hl", out / "unsupported.hl"] if args.mode == "wasm" else ["-D", "wasm", "-D", "emscripten", "-cpp", out / "unsupported"]
        failed = subprocess.run(list(map(str, [*common, "--jit", *flags])), cwd=ROOT, env=environment, capture_output=True, text=True, timeout=120)
        assert failed.returncode != 0 and "no JIT build" in failed.stdout + failed.stderr, failed.stdout + failed.stderr
    print("PASS: installed graph, CLI variants, owned concurrent queries and portable checkpoints on " + args.mode, flush=True)


if __name__ == "__main__":
    main()
