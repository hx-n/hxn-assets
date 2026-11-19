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
    "aarch64-apple-ios", "aarch64-apple-ios-sim", "aarch64-linux-android",
    "wasm32-wasip1-threads", "wasm32-unknown-emscripten", "wasm32-unknown-emscripten-threads",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-dist", action="store_true")
    args = parser.parse_args()
    version = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]["package"]["version"]
    asset = json.loads((ROOT / "packages/hxn-assets/haxelib.json").read_text())
    assert asset["version"] == asset["dependencies"]["hxn-file"] == version
    assert asset["dependencies"]["hxn"] == "0.3.9"
    ref = os.environ.get("GITHUB_REF", "")
    if ref.startswith("refs/tags/"):
        assert ref == "refs/tags/v" + version, "tag and package versions differ"
    DIST.mkdir(parents=True, exist_ok=True)
    if not args.check_dist:
        parts = ROOT / "target/release-parts"
        package = ROOT / "target/release-assembled"
        if package.exists():
            shutil.rmtree(package)
        shutil.copytree(parts / "package-linux-x86_64", package)
        for part in sorted(parts.glob("package-*")):
            manifest = json.loads((part / "haxelib.json").read_text())
            assert manifest["version"] == version and manifest["dependencies"]["hxn"] == "0.3.9"
            assert (part / "file.hxn.json").read_bytes() == (package / "file.hxn.json").read_bytes()
            shutil.copytree(part / "native", package / "native", dirs_exist_ok=True)
        for name in ("README.md", "LICENSE"):
            shutil.copy2(ROOT / "packages/hxn-file" / name, package / name)
        shutil.copytree(ROOT / "packages/hxn-file/third-party", package / "third-party", dirs_exist_ok=True)
        shutil.copytree(ROOT / "skills/hxn-file", package / "skills/hxn-file", dirs_exist_ok=True)
        for name, source in (("hxn-file", package), ("hxn-assets", ROOT / "packages/hxn-assets")):
            with zipfile.ZipFile(DIST / f"{name}-{version}.zip", "w", zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(source.rglob("*")):
                    if path.is_file():
                        archive.write(path, path.relative_to(source).as_posix())
                if name == "hxn-assets":
                    archive.write(ROOT / "skills/hxn-assets/SKILL.md", "skills/hxn-assets/SKILL.md")
    for name in ("hxn-file", "hxn-assets"):
        path = DIST / f"{name}-{version}.zip"
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            paths = set(archive.namelist())
            assert {"haxelib.json", "README.md", "LICENSE", "extraParams.hxml", "third-party/NOTICES.md", f"skills/{name}/SKILL.md"} <= paths
            meta = json.loads(archive.read("haxelib.json"))
            assert meta["name"] == name and meta["version"] == version
            assert meta["dependencies"]["hxn"] == "0.3.9"
            assert not any(p.startswith(("tests/", "adapters/", "target/")) for p in paths)
            if name == "hxn-file":
                assert {p.split("/")[1] for p in paths if p.startswith("native/")} == TARGETS
                assert "page/hxn_file.mjs" in paths
                assert "sources/hxn/file/Init.hx" in paths
            else:
                assert "src/hxn/assets/Knowledge.hx" in paths
                assert "src/hxn/assets/cli/Tool.hx" in paths
                assert meta["hxn"]["cli"]["namespace"] == "assets"
        print(f"PASS: {path.name} ({hashlib.sha256(path.read_bytes()).hexdigest()})", flush=True)


if __name__ == "__main__":
    main()
