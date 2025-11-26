use std::process::Command;
use std::env;

fn main() {
    let out = env::var("OUT_DIR").unwrap();

    Command::new("swiftc")
        .args([
            "-emit-library",
            "-o", &format!("{}/libAudioCapture.dylib", out),
            "swift/AudioCaptureManager.swift",
            "-framework", "AVFoundation",
            "-framework", "ScreenCaptureKit",
            "-framework", "CoreMedia",
            "-framework", "AppKit"
        ])
        .status()
        .expect("Swift compile failed");

    println!("cargo:rustc-link-search=native={}", out);
    println!("cargo:rustc-link-lib=dylib=AudioCapture");
}
