#!/usr/bin/env python3
"""Build both haxelibs and supported graph variants for one release platform."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtimes", nargs="+", default=["hl", "cpp"])
    parser.add_argument("--target")
    parser.add_argument("--wasm", action="store_true")
    parser.add_argument("--threads", action="store_true")
    parser.add_argument("--jit", action="store_true")
    parser.add_argument("--cli", default="hxn")
    parser.add_argument("--out", type=Path, default=ROOT / "target/release-part")
    args = parser.parse_args()
    flags = (["--target", args.target] if args.target else []) + (["--wasm"] if args.wasm else []) + (["--threads"] if args.threads else [])
    builds = [("packages/hxn-file", "file"), ("packages/hxn-assets", "assets")]
    if args.jit:
        assert not args.wasm and (not args.target or "ios" not in args.target), "JIT is unavailable on this release target"
        builds.append(("adapters/kyugraph-jit", "assets/variants/jit"))
    for source, destination in builds:
        subprocess.run([args.cli, "package", *args.runtimes, "--release", *flags, "--out", str(args.out.resolve() / destination)], cwd=ROOT / source, timeout=2400, check=True)

if __name__ == "__main__":
    main()
