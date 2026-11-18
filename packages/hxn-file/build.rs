fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    if matches!(os.as_str(), "macos" | "ios") {
        println!("cargo:rerun-if-changed=c/apple.m");
        cc::Build::new()
            .file("c/apple.m")
            .compile("hxn_file_platform");
        println!("cargo:rustc-link-lib=framework=Foundation");
    }
    if os == "emscripten" {
        println!("cargo:rerun-if-changed=page/hxn_file.mjs");
        println!("cargo:rerun-if-changed=c/direct.c");
        println!("cargo:rerun-if-changed=c/agent.c");
        let atomics = std::env::var("CARGO_CFG_TARGET_FEATURE")
            .unwrap_or_default()
            .split(',')
            .any(|v| v == "atomics");
        let mut build = cc::Build::new();
        if atomics {
            build.file("c/agent.c").flag("-pthread");
        } else {
            let agent = std::fs::read_to_string("page/hxn_file.mjs")
                .unwrap()
                .replace("export function", "function")
                .replace("import.meta.url", "location.href");
            let source = std::fs::read_to_string("c/direct.c")
                .unwrap()
                .replace("/*AGENT*/", &agent);
            let file =
                std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("direct.c");
            std::fs::write(&file, source).unwrap();
            build.file(file);
        }
        build.compile("hxn_file_agent");
    }
    if os == "android" {
        println!("cargo:rerun-if-changed=c/android.c");
        cc::Build::new()
            .file("c/android.c")
            .compile("hxn_file_platform");
        println!("cargo:rustc-link-lib=android");
    }
}
