#!/usr/bin/env python3
"""Run metadata-authored assets through FileSource and real persistent storage."""
import argparse
import os
from pathlib import Path
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MODES = ("hl", "ash", "ash-jit", "ash-interp", "cpp", "cppia", "wasm", "emcc", "emcc-threads")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modes", choices=MODES, nargs="+")
    parser.add_argument("--hxn", type=Path, default=ROOT.parent / "hxn")
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--ash", default="ash")
    parser.add_argument("--hl", default="hl")
    parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    parser.add_argument("--main", default="FilesCheck")
    parser.add_argument("--class-path", type=Path, action="append", default=[])
    parser.add_argument("--expect", default="PASS: annotated assets")
    parser.add_argument("--browser-arg", action="append", default=[])
    options = parser.parse_args()
    cli = options.cli or options.hxn / "target/debug/hxn"
    directory = ROOT / "target/assets-runtimes" / options.main
    directory.mkdir(parents=True, exist_ok=True)
    executable = ".exe" if os.name == "nt" else ""
    for mode in options.modes:
        destination = directory / mode
        destination.mkdir(exist_ok=True)
        log_path = destination / "run.log"
        with log_path.open("w") as log:
            def run(argv, cwd=ROOT, timeout=600):
                environment = os.environ.copy()
                if mode == "hl":
                    variables = ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]
                    if os.name == "nt":
                        variables.append("PATH")
                    for variable in variables:
                        environment[variable] = str(destination) + os.pathsep + environment.get(variable, "")
                if mode in ("emcc", "emcc-threads") and str(argv[0]) == "haxe":
                    environment.pop("CC", None)
                    environment.pop("CXX", None)
                result = subprocess.run([str(value) for value in argv], cwd=cwd, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
                log.flush()
                if result.returncode:
                    raise RuntimeError(f"{mode} failed; see {log_path}")

            target = "hl" if mode.startswith("ash") or mode in ("hl", "wasm") else "cppia" if mode == "cppia" else "cpp"
            wasm = mode in ("wasm", "emcc", "emcc-threads")
            threaded = mode in ("wasm", "emcc-threads")
            flags = (["--wasm"] if wasm else []) + (["--threads"] if threaded else [])
            run([cli, "build", target, *flags], cwd=ROOT / "packages/hxn-file")
            binding = "cppia" if mode == "cppia" else target + ("-wasm" if wasm else "") + ("-threads" if threaded else "")
            hxml = ROOT / "target/hxn/file" / binding / "build.hxml"
            compiler = ["haxe", hxml, "-lib", "format:3.8.0", "-cp", ROOT / "packages/hxn-assets/src", "-cp", ROOT / "tests/assets", "-cp", ROOT / "examples/knowledge",
                        "-D", "hxn_assets_dir=" + str(ROOT / "tests/fixtures/assets"), "--macro", "hxn.assets.Build.register()", "-main", options.main]
            for path in options.class_path: compiler += ["-cp",path]
            if target == "hl":
                run([*compiler, "-hl", destination / "main.hl"])
                if wasm:
                    archive = ROOT / "target/wasm32-wasip1-threads/debug/libfile_hl.a"
                    run([options.ash, "--build", destination / "main.wasm", "--target", "wasm32-wasip1-threads", "--native-lib", archive,
                         destination / "main.hl"])
                    run(["node", options.hxn / "crates/hxn-cli/src/ash_page.mjs", options.ash, destination, options.chrome,*options.browser_arg], timeout=180)
                else:
                    shutil.copy2(ROOT / "target/hxn/file/hl/file.hdll", destination / "file.hdll")
                    mode_args = ["--mode", mode.removeprefix("ash-")] if mode.startswith("ash-") else []
                    runtime = options.hl if mode == "hl" else options.ash
                    run([runtime, *mode_args, destination / "main.hl", destination / "assets", destination / "data"], timeout=60)
            elif target == "cppia":
                run([*compiler, "-cppia", destination / "main.cppia"])
                run([ROOT / ("target/hxn/file/cppia/host/out/Host" + executable), destination / "main.cppia", destination / "assets", destination / "data"], timeout=60)
            else:
                if wasm:
                    compiler += ["-D", "HXCPP_LINK_EMSCRIPTEN_EXT=.html", "-D", "HXCPP_LINK_EMRUN", "-D", "HXCPP_LINK_MEMORY_GROWTH"]
                run([*compiler, "-cpp", destination / "out"])
                if wasm:
                    stdout, stderr = destination / "page-stdout.txt", destination / "page-stderr.txt"
                    stdout.unlink(missing_ok=True)
                    stderr.unlink(missing_ok=True)
                    # Chrome children can finish profile writes after emrun exits.
                    with tempfile.TemporaryDirectory(prefix="hxn-assets-browser-", ignore_cleanup_errors=True) as profile:
                        run(["emrun", "--browser", options.chrome,
                             "--browser_args=--headless=new --no-first-run --no-default-browser-check --user-data-dir=" + profile + " " + " ".join(options.browser_arg),
                             "--kill_exit", "--timeout", "120", "--timeout-returncode", "1", "--log-stdout", stdout,
                             "--log-stderr", stderr, destination / ("out/"+options.main+".html")], timeout=180)
                    for file in (stdout, stderr):
                        if file.exists():
                            log.write(file.read_text())
                else:
                    run([destination / ("out/"+options.main+executable), destination / "out/assets", destination / "data"], timeout=60)
        if options.expect not in log_path.read_text():
            raise RuntimeError(f"{mode} did not report success; see {log_path}")
        print(f"PASS: {mode} {options.main} integration", flush=True)


if __name__ == "__main__":
    main()
