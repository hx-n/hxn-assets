#!/usr/bin/env python3
"""Install test apps, verify bundle/APK assets, relaunch persistence and URI I/O."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid
import zipfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
MOBILE = ROOT / "tests/mobile"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("ios-sim", "android"))
    parser.add_argument("runtime", choices=("hl", "cpp"))
    parser.add_argument("--device", required=True)
    parser.add_argument("--hxn", type=Path, default=ROOT.parent / "hxn")
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--ash", default="ash")
    args = parser.parse_args()
    ios = args.platform == "ios-sim"
    target = ("aarch64-apple-ios-sim" if args.runtime == "hl" else "x86_64-apple-ios") if ios else "aarch64-linux-android"
    work = ROOT / "target/mobile" / (args.platform + "-" + args.runtime)
    work.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    cli = str(args.cli or args.hxn / "target/debug/hxn")
    sdk = Path(env.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
    ndk = Path(env.get("ANDROID_NDK_ROOT", str(sdk / "ndk/27.0.12077973")))
    tools = ndk / "toolchains/llvm/prebuilt/darwin-x86_64/bin"
    java = Path(env.get("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home"))
    env.update(ANDROID_HOME=str(sdk), ANDROID_NDK_ROOT=str(ndk), ANDROID_NDK_HOME=str(ndk), NDK_ROOT=str(ndk), JAVA_HOME=str(java), IPHONEOS_DEPLOYMENT_TARGET="12.0")
    env["PATH"] = str(sdk / "platform-tools") + os.pathsep + str(java / "bin") + os.pathsep + env["PATH"]
    if not ios:
        env.update(CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=str(tools / "aarch64-linux-android26-clang"), CC_aarch64_linux_android=str(tools / "aarch64-linux-android26-clang"), AR_aarch64_linux_android=str(tools / "llvm-ar"), ASH_ANDROID_API="26")
    log = (work / "build.log").open("w")

    def run(command, cwd=ROOT, timeout=900, capture=False, extra=None, check=True):
        command = list(map(str, command))
        print("RUN:", " ".join(command), flush=True)
        log.write("RUN: " + repr(command) + "\n"); log.flush()
        if command[0].endswith("/adb"):
            timeout = min(timeout, 30)
        actual = dict(env); actual.update(extra or {})
        result = subprocess.run(command, cwd=cwd, env=actual, timeout=timeout, text=True, stdout=subprocess.PIPE if capture else log, stderr=subprocess.STDOUT, check=False)
        if capture:
            log.write(result.stdout); log.flush()
        if check and result.returncode:
            raise RuntimeError(f"Command exited {result.returncode}; see {work / 'build.log'}")
        return result.stdout if capture else result.returncode

    package = work / "package"
    run([cli, "package", args.runtime, "--target", target, "--release", "--out", package], cwd=ROOT / "packages/hxn-file")
    # The test JNI host and backend use one Cargo dependency graph for ndk-context.
    if not ios:
        crate = ROOT / "target/hxn/file" / (args.runtime + "-" + target) / "crate"
        manifest = crate / "Cargo.toml"
        data = manifest.read_text().replace("[dependencies]", '[dependencies]\nhxn-file-test-context = { path = "' + str(MOBILE / "context") + '" }')
        manifest.write_text(data)
        source = crate / "src/lib.rs"
        source.write_text(source.read_text() + "\npub use hxn_file_test_context::hxn_file_test_context;\n")
        run(["cargo", "build", "--manifest-path", manifest, "--release", "--target", target], extra={"CARGO_TARGET_DIR": str(ROOT / "target")})
        archive = ROOT / "target" / target / "release" / ("libfile_" + args.runtime + ".a")
        packaged = list(package.rglob("*.a")); assert len(packaged) == 1, packaged
        shutil.copy2(archive, packaged[0])

    spec = importlib.util.spec_from_file_location("remote_fixture", ROOT / "tests/assets/remote.py")
    remote = importlib.util.module_from_spec(spec); spec.loader.exec_module(remote)
    appid = "dev.hxn.assets.check." + args.runtime
    adb = [str(sdk / "platform-tools/adb"), "-s", args.device]
    with remote.fixture() as (remote_dir, ports):
        assets = work / "input-assets"
        shutil.copytree(ROOT / "tests/fixtures/assets", assets, dirs_exist_ok=True)
        nonce = uuid.uuid4().hex
        (assets / "test-run.txt").write_text(nonce)
        out = work / "out"; out.mkdir(exist_ok=True)
        flags = ["haxe", "-lib", "format:3.8.0", "-cp", args.hxn / "haxe", "-cp", package, package / "extraParams.hxml", "-cp", ROOT / "packages/hxn-assets/src", "-cp", ROOT / "tests/assets", "-cp", MOBILE, "-cp", remote_dir, "--macro", "hxn.assets.Build.register()", "-D", "hxn_assets_dir=" + str(assets), "-D", "hxn_triple=" + target, "-D", "hxn_file_mobile", "-resource", str(assets / "test-run.txt") + "@mobile-nonce", "-main", "MobileCheck"]
        if not ios: flags += ["-D", "hxn_mobile_android"]
        if args.runtime == "hl":
            run([*flags, "-hl", out / "main.hl"])
            extra = {"ASH_LINK_ARGS": "-framework Foundation -liconv -lobjc" if ios else "--target=aarch64-linux-android26 -shared -Wl,-soname,libhxn_asset_check.so -landroid -llog"}
            native = ["--native-lib", out / "libfile.a"]
            if not ios:
                run([tools / "aarch64-linux-android26-clang", "-fPIC", "-c", MOBILE / "android/host.c", "-o", out / "host.o"])
                native += ["--native-lib", out / "host.o"]
            run([args.ash, "--build", out / ("Check" if ios else "libhxn_asset_check.so"), "--target", target, *native, out / "main.hl"], cwd=out, extra=extra)
        else:
            if ios:
                # libtool builds an archive; SDK dylibs are linked by the final app host.
                original = ET.parse(package / "native" / target / "link.xml").getroot()
                for node in original.iter("lib"):
                    name = node.get("name", "")
                    if name.startswith("-l"):
                        node.tag = "flag"; node.attrib = {"value": "-ref-" + name[1:]}
                for node in original.iter("flag"):
                    if node.get("value") == "-framework": node.set("value", "-ref-framework")
                deferred = work / "archive-link.xml"
                ET.ElementTree(original).write(deferred, encoding="unicode")
                flags += ["--macro", "haxe.macro.Compiler.define(\"FILE_LINK\", " + json.dumps(str(deferred)) + ")"]
                defines = ["-D", "iphonesim", "-D", "HXCPP_M64", "-D", "HXCPP_IOS_MIN_VERSION=12.0"]
            else:
                run([tools / "aarch64-linux-android26-clang", "-fPIC", "-DHXN_CHECK_CPP", "-c", MOBILE / "android/host.c", "-o", out / "host.o"])
                xml = work / "host.xml"
                xml.write_text('<xml><target id="haxe"><lib name="' + escape(str(out / "host.o")) + '"/><lib name="-llog"/></target></xml>')
                defines = ["-D", "android", "-D", "HXCPP_ARM64", "-D", "HXCPP_DEBUG_LINK", "-D", "ANDROID_HOST=darwin-x86_64", "-D", "HXCPP_ANDROID_PLATFORM=26", "-D", "hxn_mobile_xml=" + str(xml)]
            run([*flags, "-cpp", out, *defines])
            if ios:
                library = list(out.glob("libMobileCheck*.a")); assert len(library) == 1, library
                run(["xcrun", "--sdk", "iphonesimulator", "clang++", "-arch", "x86_64", "-mios-simulator-version-min=12.0", MOBILE / "ios.cpp", library[0], "-framework", "Foundation", "-framework", "QuartzCore", "-liconv", "-lobjc", "-o", out / "Check"])
            else:
                shutil.copy2(out / "libMobileCheck-64.so", out / "libhxn_asset_check.so")

        forwarded = []
        try:
            if ios:
                app = work / "Check.app"; app.mkdir(exist_ok=True)
                shutil.copy2(out / "Check", app / "Check")
                shutil.copytree(out / "assets", app / "assets", dirs_exist_ok=True)
                with (app / "Info.plist").open("wb") as f:
                    plistlib.dump({"CFBundleExecutable":"Check", "CFBundleIdentifier":appid, "CFBundleName":"AssetCheck", "CFBundlePackageType":"APPL", "CFBundleVersion":"1", "CFBundleShortVersionString":"1.0", "CFBundleSupportedPlatforms":["iPhoneSimulator"], "MinimumOSVersion":"12.0", "LSRequiresIPhoneOS":True, "UIDeviceFamily":[1,2]}, f)
                run(["codesign", "--force", "--sign", "-", app])
                run(["xcrun", "simctl", "uninstall", args.device, appid], check=False)
                run(["xcrun", "simctl", "install", args.device, app])
            else:
                build = sdk / "build-tools/36.1.0"; jar = sdk / "platforms/android-35/android.jar"
                classes = work / "classes"; classes.mkdir(exist_ok=True)
                dex = work / "dex"; dex.mkdir(exist_ok=True)
                run([java / "bin/javac", "-source", "8", "-target", "8", "-bootclasspath", jar, "-d", classes, MOBILE / "android/CheckActivity.java"])
                run([build / "d8", "--min-api", "26", "--lib", jar, "--output", dex, *sorted(classes.rglob("*.class"))])
                manifest = work / "AndroidManifest.xml"
                manifest.write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="'+appid+'"><uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/><uses-permission android:name="android.permission.INTERNET"/><application android:debuggable="true" android:extractNativeLibs="true" android:label="Asset check"><activity android:name="hxn.assets.test.CheckActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity></application></manifest>')
                apk = work / "check.apk"
                run([build / "aapt2", "link", "--manifest", manifest, "-I", jar, "-o", apk])
                with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
                    z.write(dex / "classes.dex", "classes.dex")
                    z.write(out / "libhxn_asset_check.so", "lib/arm64-v8a/libhxn_asset_check.so")
                    for asset in (out / "assets").rglob("*"):
                        if asset.is_file(): z.write(asset, "assets/" + str(asset.relative_to(out / "assets")))
                key = work / "test.keystore"
                if not key.exists(): run([java / "bin/keytool", "-genkeypair", "-keystore", key, "-storepass", "android", "-keypass", "android", "-alias", "test", "-dname", "CN=Asset test", "-keyalg", "RSA", "-validity", "3650"])
                run([build / "apksigner", "sign", "--ks", key, "--ks-pass", "pass:android", apk])
                run([*adb, "uninstall", appid], check=False)
                run([*adb, "install", apk])
                for port in ports:
                    run([*adb, "reverse", "tcp:" + str(port), "tcp:" + str(port)])
                    forwarded.append(port)
            for suite, expected in [("storage", "PASS: mobile assets write " + nonce), ("storage", "PASS: mobile assets reopen " + nonce), ("remote", "PASS: mobile remote " + nonce)]:
                if ios:
                    output = run(["xcrun", "simctl", "launch", "--console", "--terminate-running-process", args.device, appid], timeout=90, capture=True, extra={"SIMCTL_CHILD_HXN_ASSET_SUITE":suite})
                else:
                    run([*adb, "shell", "am", "force-stop", appid])
                    run([*adb, "shell", "am", "start", "-n", appid + "/hxn.assets.test.CheckActivity", "--ez", "remote", "true" if suite == "remote" else "false"])
                    deadline = time.monotonic() + 90
                    while True:
                        output = run([*adb, "logcat", "-d", "-v", "raw", "-s", "hxn-assets-check:V", "trace:V", "AndroidRuntime:E"], capture=True)
                        if expected in output: break
                        if time.monotonic() >= deadline: raise AssertionError(output)
                        time.sleep(0.5)
                print("\n".join(line for line in output.splitlines() if expected in line), flush=True)
                assert expected in output, output
        finally:
            if ios: run(["xcrun", "simctl", "uninstall", args.device, appid], check=False)
            else:
                run([*adb, "uninstall", appid], check=False)
                for port in forwarded: run([*adb, "reverse", "--remove", "tcp:" + str(port)], check=False)
    log.close()
    print("PASS:", args.platform, args.runtime, "bundle/APK, relaunch persistence, shared logs, HTTP/WS/WSS", flush=True)


if __name__ == "__main__":
    main()
