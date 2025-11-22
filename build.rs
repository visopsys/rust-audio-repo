use std::process::Command;
use std::env;

fn main() {
    let out = env::var("OUT_DIR").unwrap();

    Command::new("swiftc")
        .args([
            "-emit-library",
            "-o", &format!("{}/libAudioCapture.dylib", out),
            "macos/AudioCaptureManager.swift",
            "macos/AudioBridge.swift",
            "-framework", "AVFoundation",
            "-framework", "ScreenCaptureKit",
            "-framework", "CoreMedia",
            "-framework", "CoreAudio"
        ])
        .status()
        .expect("Swift compile failed");

    println!("cargo:rustc-link-search=native={}", out);
    println!("cargo:rustc-link-lib=dylib=AudioCapture");
}
