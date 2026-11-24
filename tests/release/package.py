#!/usr/bin/env python3
"""Assemble and validate the two installed haxelibs from CI platform artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / "target/release-dist"
TARGETS = {
    "x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu",
    "aarch64-apple-darwin", "x86_64-apple-darwin", "x86_64-pc-windows-msvc",
    "aarch64-apple-ios", "aarch64-apple-ios-sim", "aarch64-linux-android", "x86_64-linux-android",
    "wasm32-wasip1-threads", "wasm32-unknown-emscripten", "wasm32-unknown-emscripten-threads",
}

JIT_TARGETS = {t for t in TARGETS if not t.startswith("wasm") and "ios" not in t}

def merge(parts, source, destination, manifest):
    shutil.copytree(parts / "package-linux-x86_64" / source, destination)
    for part in sorted(parts.glob("package-*")):
        package = part / source
        if not package.exists():
            continue
        assert (package / manifest).read_bytes() == (destination / manifest).read_bytes(), str(package)
        for directory in ("native", "page"):
            if (package / directory).exists():
                shutil.copytree(package / directory, destination / directory, dirs_exist_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-dist", action="store_true")
    args = parser.parse_args()
    version = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]["package"]["version"]
    asset = json.loads((ROOT / "packages/hxn-assets/haxelib.json").read_text())
    assert asset["version"] == asset["dependencies"]["hxn-file"] == version
    assert asset["dependencies"]["hxn"] == "0.3.10"
    ref = os.environ.get("GITHUB_REF", "")
    if ref.startswith("refs/tags/"):
        assert ref == "refs/tags/v" + version, "tag and package versions differ"
    DIST.mkdir(parents=True, exist_ok=True)
    if not args.check_dist:
        parts = ROOT / "target/release-parts"
        package = ROOT / "target/release-assembled"
        if package.exists():
            shutil.rmtree(package)
        file = package / "file"
        assets = package / "assets"
        merge(parts, "file", file, "file.hxn.json")
        merge(parts, "assets", assets, "assets.hxn.json")
        # JIT binaries are variants of the same installed Haxelib.
        shutil.rmtree(assets / "variants", ignore_errors=True)
        merge(parts, "assets/variants/jit", assets / "variants/jit", "assets_jit.hxn.json")
        for name, destination in (("hxn-file", file), ("hxn-assets", assets)):
            source = ROOT / "packages" / name
            for filename in ("README.md", "LICENSE"):
                shutil.copy2(source / filename, destination / filename)
            shutil.copytree(source / "third-party", destination / "third-party", dirs_exist_ok=True)
            shutil.copytree(ROOT / "skills" / name, destination / "skills" / name, dirs_exist_ok=True)
            if name == "hxn-assets":
                shutil.copytree(source / "src", destination / "src", dirs_exist_ok=True)
                for filename in ("haxelib.json", "extraParams.hxml"):
                    shutil.copy2(source / filename, destination / filename)
            with zipfile.ZipFile(DIST / f"{name}-{version}.zip", "w", zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(destination.rglob("*")):
                    if path.is_file():
                        archive.write(path, path.relative_to(destination).as_posix())
    for name in ("hxn-file", "hxn-assets"):
        path = DIST / f"{name}-{version}.zip"
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            paths = set(archive.namelist())
            assert {"haxelib.json", "README.md", "LICENSE", "extraParams.hxml", "third-party/NOTICES.md", f"skills/{name}/SKILL.md"} <= paths
            meta = json.loads(archive.read("haxelib.json"))
            assert meta["name"] == name and meta["version"] == version
            assert meta["dependencies"]["hxn"] == "0.3.10"
            assert not any(p.startswith(("tests/", "adapters/", "target/")) for p in paths)
            if name == "hxn-file":
                assert {p.split("/")[1] for p in paths if p.startswith("native/")} == TARGETS
                assert "page/hxn_file.mjs" in paths
                assert "sources/hxn/file/Init.hx" in paths
            else:
                assert {p.split("/")[1] for p in paths if p.startswith("native/")} == TARGETS
                assert {p.split("/")[3] for p in paths if p.startswith("variants/jit/native/")} == JIT_TARGETS
                assert {"assets.hxn.json", "variants/jit/assets_jit.hxn.json", "src/hxn/assets/KnowledgeGraph.hx", "src/hxn/assets/NativeBuild.hx", "third-party/native/inventory.json"} <= paths
                assert not any(p.endswith(".rs") or p.endswith("Cargo.toml") for p in paths)
                assert "src/hxn/assets/Knowledge.hx" in paths
                assert "src/hxn/assets/cli/Tool.hx" in paths
                assert meta["hxn"]["cli"]["namespace"] == "assets"
        print(f"PASS: {path.name} ({hashlib.sha256(path.read_bytes()).hexdigest()})", flush=True)


if __name__ == "__main__":
    main()
