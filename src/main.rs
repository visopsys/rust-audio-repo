use std::ffi::c_void;
use std::thread;
use std::time::Duration;
use std::sync::Mutex;
use hound::{WavWriter, WavSpec};

const OUTPUT_FILE: &str = "output.wav";

// Global WAV writer wrapped in a mutex for thread-safe access
static WAV_WRITER: Mutex<Option<WavWriter<std::io::BufWriter<std::fs::File>>>> = Mutex::new(None);

// Link to Swift dylib
#[link(name = "AudioCapture", kind = "dylib")]
extern "C" {
    fn set_audio_callback(cb: *const c_void);
    fn start_audio_recording();
    fn stop_audio_recording();
}

fn init_wav_writer(filename: &str) {
    // macOS ScreenCaptureKit audio format:
    // 48kHz sample rate, 2 channels (stereo), 32-bit float, non-interleaved
    let spec = WavSpec {
        channels: 2,
        sample_rate: 48000,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };

    let writer = WavWriter::create(filename, spec).expect("Failed to create WAV file");
    *WAV_WRITER.lock().unwrap() = Some(writer);
    println!("💾 WAV writer initialized: {} (stereo, 48kHz, 32-bit float)", filename);
}

fn close_wav_writer() {
    if let Some(writer) = WAV_WRITER.lock().unwrap().take() {
        writer.finalize().expect("Failed to finalize WAV file");
        println!("💾 WAV file finalized");
    }
}

// Callback to receive raw PCM bytes from Swift
extern "C" fn on_audio_data(data: *const u8, length: u32) {
    if data.is_null() || length == 0 {
        return;
    }

    let slice = unsafe { std::slice::from_raw_parts(data, length as usize) };

    // Convert bytes to f32 samples (32-bit float)
    let samples: &[f32] = unsafe {
        std::slice::from_raw_parts(
            slice.as_ptr() as *const f32,
            slice.len() / std::mem::size_of::<f32>()
        )
    };

    // Audio is non-interleaved (planar): [L, L, L...] [R, R, R...]
    // WAV needs interleaved: [L, R, L, R, L, R...]
    let num_samples = samples.len();
    let samples_per_channel = num_samples / 2;

    let left_channel = &samples[0..samples_per_channel];
    let right_channel = &samples[samples_per_channel..num_samples];

    // Write samples to WAV file in interleaved format
    if let Some(writer) = WAV_WRITER.lock().unwrap().as_mut() {
        for i in 0..samples_per_channel {
            writer.write_sample(left_channel[i]).expect("Failed to write sample");
            writer.write_sample(right_channel[i]).expect("Failed to write sample");
        }
    }

    println!("🎧 Wrote {} samples ({} bytes)", num_samples, slice.len());
}

fn main() {
    // Initialize WAV writer
    init_wav_writer(OUTPUT_FILE);

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

    // Finalize WAV file
    close_wav_writer();
    println!("✅ Recording saved to {}", OUTPUT_FILE);
}
