use std::process::Command;
use std::env;

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();

    let bridge_header = "macos/AudioBridge.h";
    let swift_src = "macos/AudioCaptureManager.swift";
    let lib_path = format!("{}/libAudioCapture.dylib", out_dir);

    // target triple depending on arch
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
            "-I", "macos", // so swiftc can see the header if needed
        ])
        .status()
        .expect("failed to run swiftc");

    if !status.success() {
        panic!("swiftc failed to compile Swift sources");
    }

    println!("cargo:rustc-link-search=native={}", out_dir);
    println!("cargo:rustc-link-lib=dylib=AudioCapture");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=ScreenCaptureKit");
    println!("cargo:rustc-link-lib=framework=CoreAudio");
    println!("cargo:rustc-link-lib=framework=CoreMedia");

    println!("cargo:rerun-if-changed={}", bridge_header);
    println!("cargo:rerun-if-changed={}", swift_src);
}
