use eframe::egui;
use std::sync::{Arc, Mutex};
use std::ffi::c_void;

// Link to the Swift-produced dylib
#[link(name = "AudioCapture", kind = "dylib")]
extern "C" {
    fn set_audio_callback(cb: *const c_void);
    fn start_audio_recording();
    fn stop_audio_recording();
}

// The Rust callback to receive raw PCM bytes from Swift.
// extern "C" so it can be passed as a C function pointer.
extern "C" fn on_audio_data(data: *const u8, length: u32) {
    if data.is_null() || length == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, length as usize) };
    println!("🎧 Received {} bytes of audio", slice.len());

    // Here you can stream these bytes over network, push to encoder, etc.
}

// Helper to register the callback (call before start)
fn register_callback() {
    // cast the Rust fn pointer to *const c_void
    let func_ptr = on_audio_data as *const ();
    unsafe {
        set_audio_callback(func_ptr as *const c_void);
    }
    println!("🔗 Registered Rust audio callback with Swift");
}

fn unregister_callback() {
    unsafe {
        set_audio_callback(std::ptr::null());
    }
    println!("🔗 Cleared audio callback");
}

// GUI app
#[derive(Default)]
struct AudioApp {
    is_recording: Arc<Mutex<bool>>,
    registered: bool,
}

impl eframe::App for AudioApp {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("🎙️ Live System Audio Recorder (Rust + macOS)");
            ui.add_space(20.0);

            let mut recording = self.is_recording.lock().unwrap();
            if !*recording {
                if ui.button("▶️ Start Recording").clicked() {
                    // register callback then start
                    if !self.registered {
                        register_callback();
                        self.registered = true;
                    }
                    unsafe { start_audio_recording() };
                    *recording = true;
                }
            } else if ui.button("⏹ Stop Recording").clicked() {
                unsafe { stop_audio_recording() };
                *recording = false;
            }

            ui.add_space(10.0);
            if ui.button("Unregister Callback").clicked() {
                unregister_callback();
                self.registered = false;
            }

        });
    }
}

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "Live System Audio Recorder",
        options,
        Box::new(|_| Box::new(AudioApp::default())),
    )
}
