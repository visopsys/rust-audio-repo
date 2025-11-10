use std::process::Command;
use std::path::Path;

fn main() {
    // Output directory for Cargo
    let out_dir = std::env::var("OUT_DIR").unwrap();

    // Paths to your Swift source files
    let bridge = "macos/AudioBridge.swift";
    let manager = "macos/AudioCaptureManager.swift";
    let lib_path = format!("{}/libAudioCapture.dylib", out_dir);

    // Compile Swift files into a dynamic library (.dylib)
    let status = Command::new("swiftc")
        .args([
            "-emit-library",
            "-o", &lib_path,
            bridge,
            manager,
            "-target", "x86_64-apple-macosx13.0",
            "-import-objc-header", "macos/AudioBridge.h",
            "-framework", "Foundation",
            "-framework", "AVFoundation",
            "-framework", "ScreenCaptureKit",
        ])
        .status()
        .expect("failed to run swiftc");

    if !status.success() {
        panic!("swiftc failed to compile Swift sources");
    }

    // Tell Cargo where to find the dynamic library
    println!("cargo:rustc-link-search=native={}", out_dir);
    println!("cargo:rustc-link-lib=dylib=AudioCapture"); // Link dynamic library

    // Link required macOS frameworks
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=ScreenCaptureKit");

    // Re-run build.rs if Swift files change
    println!("cargo:rerun-if-changed={}", bridge);
    println!("cargo:rerun-if-changed={}", manager);
    println!("cargo:rerun-if-changed=macos/AudioBridge.h");
}

