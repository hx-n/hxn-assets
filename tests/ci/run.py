#!/usr/bin/env python3
"""Run the repository's existing fixtures with bounded CI invocations."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("native", "wasm", "emcc", "emcc-threads"))
    parser.add_argument("--hxn", type=Path, default=ROOT / "tests/.tools/hxn")
    parser.add_argument("--cli", default="hxn")
    parser.add_argument("--ash", default="ash")
    parser.add_argument("--chrome", default="google-chrome")
    options = parser.parse_args()

    environment = os.environ.copy()
    environment["HXN_BROWSER"] = options.chrome

    def run(command, cwd=ROOT):
        print("RUN:", " ".join(map(str, command)), flush=True)
        subprocess.run(list(map(str, command)), cwd=cwd, env=environment, timeout=1200, check=True)

    if options.mode == "native":
        modes = ["ash", "ash-jit", "ash-interp", "cpp", "cppia"]
        if sys.platform != "darwin":
            modes.insert(0, "hl")
    else:
        modes = [options.mode]
    common = ["--hxn", options.hxn.resolve(), "--cli", options.cli, "--ash", options.ash,
              "--chrome", options.chrome]
    # Source graph fixtures and file bindings share one profile and toolchain.
    package = ROOT / "target/ci-file-sdk"
    package_flags = [] if options.mode == "native" else ["--wasm"]
    if options.mode in ("wasm", "emcc-threads"):
        package_flags.append("--threads")
    runtimes = ["hl", "cpp"] if options.mode == "native" else ["hl" if options.mode == "wasm" else "cpp"]
    run([options.cli, "package", *runtimes, *package_flags, "--out", package], ROOT / "packages/hxn-file")
    run(["haxelib", "dev", "hxn-file", package])
    for mode in modes:
        if options.mode == "native":
            runtime = mode if mode in ("cpp", "cppia") else "hl"
            vm = {
                "ash": options.ash,
                "ash-jit": options.ash + " --mode jit",
                "ash-interp": options.ash + " --mode interp",
            }.get(mode)
            flags = ["--vm", vm] if vm else []
        else:
            runtime = "hl" if mode == "wasm" else "cpp"
            flags = ["--wasm", "--browser"]
            if mode in ("wasm", "emcc-threads"):
                flags.append("--threads")
            if runtime == "hl":
                flags += ["--vm", options.ash]
        run([options.cli, "check", runtime, *flags], ROOT / "packages/hxn-file")
        for graph in (("packages/hxn-assets", "adapters/kyugraph-jit") if options.mode == "native" else ("packages/hxn-assets",)):
            if mode == "wasm":
                # The source CLI links its own archive; this composed fixture also needs file.
                run([options.cli, "build", "hl", "--wasm", "--threads"], ROOT / graph)
                metadata = tomllib.loads((ROOT / graph / "Cargo.toml").read_text())["package"]["metadata"]["hxn"]
                out = ROOT / "target/hxn/assets/hl-wasm-threads"
                run(["haxe", out / "build.hxml", "-cp", ROOT / "tests/knowledge-native", "-main", "Main",
                     *metadata["haxe-flags"], "-hl", out / "main.hl"], ROOT / graph)
                libraries = [arg for path in sorted(out.glob("lib*.a")) for arg in ("--native-lib", path)]
                assert (out / "libfile.a").is_file(), "the composed graph fixture needs its file SDK"
                run([options.ash, "--build", out / "main.wasm", "--target", "wasm32-wasip1-threads",
                     *libraries, out / "main.hl"])
                run(["node", options.hxn / "crates/hxn-cli/src/ash_page.mjs", options.ash, out, options.chrome])
            else:
                run([options.cli, "check", runtime, *flags], ROOT / graph)
        run([sys.executable, ROOT / "tests/assets/runtimes.py", mode, *common])
        run([sys.executable, ROOT / "tests/assets/remote.py", mode, *common])



if __name__ == "__main__":
    main()
