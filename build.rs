use std::process::Command;
use std::env;

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();
    let swift_src = "macos/AudioCaptureManager.swift";
    let lib_path = format!("{}/libAudioCapture.dylib", out_dir);

    let target = if cfg!(target_arch = "aarch64") {
        "arm64-apple-macosx13.0"
    } else {
        "x86_64-apple-macosx13.0"
    };

    let status = Command::new("swiftc")
        .args([
            "-emit-library",
            "-o", &lib_path,
            swift_src,
            "-target", target,
            "-Xlinker", "-undefined",
            "-Xlinker", "dynamic_lookup",
            "-framework", "Foundation",
            "-framework", "AVFoundation",
            "-framework", "ScreenCaptureKit",
            "-framework", "CoreAudio",
            "-framework", "CoreMedia",
            "-I", "macos",
        ])
        .status()
        .expect("failed to run swiftc");

    if !status.success() {
        panic!("swiftc failed");
    }

    println!("cargo:rustc-link-search=native={}", out_dir);
    println!("cargo:rustc-link-lib=dylib=AudioCapture");
}
