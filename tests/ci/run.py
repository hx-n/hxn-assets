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
    parser.add_argument("--hxn", type=Path, default=ROOT / "target/hxn-source")
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
        checks = [("hl", options.ash), ("hl", options.ash + " --mode jit"),
                  ("hl", options.ash + " --mode interp"), ("cpp", None), ("cppia", None)]
        if sys.platform != "darwin":
            modes.insert(0, "hl")
            checks.insert(0, ("hl", None))
        for runtime, vm in checks:
            run([options.cli, "check", runtime, *(["--vm", vm] if vm else [])], ROOT / "packages/hxn-file")
    else:
        modes = [options.mode]
        target = "hl" if options.mode == "wasm" else "cpp"
        flags = ["--wasm", "--browser"]
        if options.mode in ("wasm", "emcc-threads"):
            flags.append("--threads")
        if target == "hl":
            flags += ["--vm", options.ash]
        run([options.cli, "check", target, *flags], ROOT / "packages/hxn-file")
    common = ["--hxn", options.hxn.resolve(), "--cli", options.cli, "--ash", options.ash,
              "--chrome", options.chrome]
    run([sys.executable, ROOT / "tests/assets/runtimes.py", *modes, *common])
    run([sys.executable, ROOT / "tests/assets/remote.py", *modes, *common])


if __name__ == "__main__":
    main()
