#!/usr/bin/env python3
"""Verify immutable release ZIPs and submit only missing Haxelib versions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--dist", type=Path, default=ROOT / "target/release-dist")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    assert re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag)
    version = args.tag[1:]
    repository = os.environ.get("GITHUB_REPOSITORY", "hx-n/hxn-assets")

    def output(argv):
        return subprocess.check_output(argv, cwd=ROOT, text=True, timeout=120).strip()

    def tagged(path):
        return output(["git", "show", args.tag + ":" + path])

    revision = output(["git", "rev-parse", args.tag + "^{commit}"])
    remote = json.loads(output(["gh", "api", f"repos/{repository}/commits/{args.tag}"]))
    assert remote["sha"] == revision, "local and public release tags differ"
    release = json.loads(output(["gh", "api", f"repos/{repository}/releases/tags/{args.tag}"]))
    assert not release["draft"] and release["tag_name"] == args.tag
    assets = {a["name"]: a for a in release["assets"]}
    cargo = tomllib.loads(tagged("Cargo.toml"))
    assert cargo["workspace"]["package"]["version"] == version
    core = cargo["workspace"]["dependencies"]["hxn"]["tag"].removeprefix("v")
    sums = dict(line.split(None, 1)[::-1] for line in (args.dist / "SHA256SUMS").read_text().splitlines())
    sums = {name.strip().removeprefix("*"): digest for name, digest in sums.items()}
    archives = []
    for name in ("hxn-file", "hxn-assets"):
        path = args.dist / f"{name}-{version}.zip"
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert sums[path.name] == digest, "release checksum mismatch"
        assert assets[path.name].get("digest") == "sha256:" + digest, "GitHub asset digest mismatch"
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            meta = json.loads(archive.read("haxelib.json"))
            assert meta["name"] == name and meta["version"] == version
            assert meta["dependencies"]["hxn"] == core
            if name == "hxn-assets":
                assert meta == json.loads(tagged("packages/hxn-assets/haxelib.json"))
            for required in ("LICENSE", "README.md", "extraParams.hxml", "third-party/NOTICES.md", f"skills/{name}/SKILL.md"):
                assert required in archive.namelist()
        archives.append((name, path))
        print("PASS: immutable release archive " + path.name, flush=True)
    if args.check_only:
        return
    password = os.environ.get("HAXELIB_PASSWORD")
    if not password:
        raise SystemExit("Configure HAXELIB_PASSWORD before publishing")

    def published(name):
        result = subprocess.run(["haxelib", "info", name], capture_output=True, text=True, timeout=90)
        text = result.stdout + result.stderr
        if result.returncode and "No such Project" not in text:
            raise RuntimeError("Could not verify Haxelib publication for " + name)
        return any(line.strip() == "Version: " + version or re.match(r"^\s*\d{4}-\d{2}-\d{2}\s+\S+\s+" + re.escape(version) + r"\s*:", line) for line in text.splitlines())

    for name, path in archives:
        for attempt in range(3):
            if published(name):
                print("PASS: Haxelib already has " + name + " " + version, flush=True)
                break
            try:
                result = subprocess.run(["haxelib", "submit", str(path), "darmie", password, "--never"], capture_output=True, text=True, timeout=600, stdin=subprocess.DEVNULL)
                text = (result.stdout + result.stderr).replace(password, "[redacted]")
            except subprocess.TimeoutExpired:
                text = "Haxelib upload timed out; checking whether the server accepted it"
            print("\n".join(line for line in text.splitlines() if not re.fullmatch(r"\d+%", line)), flush=True)
            if "Invalid password" in text:
                raise SystemExit("Haxelib rejected HAXELIB_PASSWORD for darmie")
            if published(name):
                print("PASS: published " + name + " " + version, flush=True)
                break
            if attempt == 2:
                raise SystemExit("Haxelib did not accept " + name + " " + version)
            time.sleep(5 * (attempt + 1))


if __name__ == "__main__":
    main()
