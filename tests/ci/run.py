#!/usr/bin/env python3
"""Run the repository's existing fixtures with bounded CI invocations."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

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
        run([sys.executable, ROOT / "tests/assets/runtimes.py", mode, *common])
        run([sys.executable, ROOT / "tests/assets/remote.py", mode, *common])



if __name__ == "__main__":
    main()
