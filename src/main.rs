use std::ffi::c_void;
use std::thread;
use std::time::Duration;

extern "C" {
    fn set_audio_callback(cb: *const c_void);
    fn start_audio_recording();
    fn stop_audio_recording();
}

extern "C" fn on_audio(data: *const u8, len: u32) {
    if !data.is_null() && len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(data, len as usize) };
        println!("🎧 Rust received {} bytes", slice.len());
    }
}

fn main() {
    unsafe { set_audio_callback(on_audio as *const c_void) };

    unsafe { start_audio_recording() };
    println!("🎙️ Recording… running in background");

    thread::sleep(Duration::from_secs(10));

    unsafe { stop_audio_recording() };
    println!("🛑 Stopped");
}
