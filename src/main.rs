use std::ffi::c_void;
use std::thread;
use std::time::Duration;

// Link to Swift dylib
#[link(name = "AudioCapture", kind = "dylib")]
extern "C" {
    fn set_audio_callback(cb: *const c_void);
    fn start_audio_recording();
    fn stop_audio_recording();
}

// Callback to receive raw PCM bytes from Swift
extern "C" fn on_audio_data(data: *const u8, length: u32) {
    if data.is_null() || length == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, length as usize) };
    println!("🎧 Received {} bytes of audio", slice.len());
}

fn main() {
    // Register callback
    let func_ptr = on_audio_data as *const ();
    unsafe { set_audio_callback(func_ptr as *const c_void) };
    println!("🔗 Registered audio callback");

    // Start recording
    unsafe { start_audio_recording() };
    println!("🎙️ Recording started…");

    // Record for 5 seconds
    thread::sleep(Duration::from_secs(5));

    // Stop recording
    unsafe { stop_audio_recording() };
    println!("🛑 Recording stopped");

    // Clear callback
    unsafe { set_audio_callback(std::ptr::null()) };
    println!("🔗 Callback cleared");
}
