use eframe::egui;
use std::ffi::CString;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

#[link(name = "AudioCapture", kind = "static")]
extern "C" {
    fn start_audio_recording(path: *const std::os::raw::c_char);
    fn stop_audio_recording();
}

#[derive(Default)]
struct AudioApp {
    is_recording: Arc<Mutex<bool>>,
}

impl eframe::App for AudioApp {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("🎙️ System Audio Recorder (Rust + macOS)");
            ui.add_space(20.0);

            let mut recording = self.is_recording.lock().unwrap();
            if !*recording {
                if ui.button("▶️ Start Recording").clicked() {
                    *recording = true;
                    start_recording_rust();
                }
            } else {
                if ui.button("⏹ Stop Recording").clicked() {
                    *recording = false;
                    stop_recording_rust();
                }
            }
        });
    }
}

fn start_recording_rust() {
    let output = PathBuf::from("/Users/Shared/system_audio.m4a");
    let c_path = CString::new(output.to_string_lossy().to_string()).unwrap();
    unsafe {
        start_audio_recording(c_path.as_ptr());
    }
    println!("🎧 Recording started…");
}

fn stop_recording_rust() {
    unsafe {
        stop_audio_recording();
    }
    println!("🛑 Recording stopped.");
}

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "System Audio Recorder",
        options,
        Box::new(|_| Box::new(AudioApp::default())),
    )
}
