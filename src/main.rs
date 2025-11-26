use std::slice;

extern "C" {
    fn set_audio_callback(cb: Option<extern "C" fn(*const u8, u32)>);
    fn start_audio_recording();
    fn stop_audio_recording();
    fn run_main_loop_for(seconds: f64);
}

extern "C" fn on_audio(data: *const u8, len: u32) {
    if !data.is_null() && len > 0 {
        let slice = unsafe { slice::from_raw_parts(data, len as usize) };
        println!("🎧 Rust received {} bytes", slice.len());
    }
}

fn main() {
    unsafe { set_audio_callback(Some(on_audio)) };

    println!("🎙️ Starting recording…");
    unsafe { start_audio_recording() };

    // Run 15 seconds
    unsafe { run_main_loop_for(15.0) };

    unsafe { stop_audio_recording() };

    println!("🛑 Recording stopped. Check ~/merged_audio.m4a");
}
