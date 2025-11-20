use std::ffi::c_void;
use std::thread;
use std::time::Duration;
use std::sync::Mutex;
use std::fs::File;
use std::io::Write;
use std::mem::MaybeUninit;
use mp3lame_encoder::{Builder, FlushNoGap, InterleavedPcm};

const OUTPUT_FILE: &str = "output.mp3";

// Global MP3 encoder and output buffer
static MP3_ENCODER: Mutex<Option<(mp3lame_encoder::Encoder, File)>> = Mutex::new(None);

// Link to Swift dylib
#[link(name = "AudioCapture", kind = "dylib")]
extern "C" {
    fn set_audio_callback(cb: *const c_void);
    fn start_audio_recording();
    fn stop_audio_recording();
}

fn init_mp3_encoder(filename: &str) {
    // Configure MP3 encoder for high-quality stereo audio
    let mut encoder = Builder::new().expect("Failed to create MP3 encoder builder");
    encoder.set_num_channels(2).expect("Failed to set channels");
    encoder.set_sample_rate(48000).expect("Failed to set sample rate");
    encoder.set_brate(mp3lame_encoder::Bitrate::Kbps320).expect("Failed to set bitrate");
    encoder.set_quality(mp3lame_encoder::Quality::Best).expect("Failed to set quality");

    let encoder = encoder.build().expect("Failed to build MP3 encoder");
    let file = File::create(filename).expect("Failed to create MP3 file");

    *MP3_ENCODER.lock().unwrap() = Some((encoder, file));
    println!("💾 MP3 encoder initialized: {} (stereo, 48kHz, 320kbps)", filename);
}

fn close_mp3_encoder() {
    if let Some((mut encoder, mut file)) = MP3_ENCODER.lock().unwrap().take() {
        // Flush any remaining data
        let mut mp3_buffer: [MaybeUninit<u8>; 16384] = unsafe { MaybeUninit::uninit().assume_init() };
        if let Ok(encoded_size) = encoder.flush::<FlushNoGap>(&mut mp3_buffer[..]) {
            if encoded_size > 0 {
                let data = unsafe {
                    std::slice::from_raw_parts(mp3_buffer.as_ptr() as *const u8, encoded_size)
                };
                file.write_all(data).expect("Failed to write final MP3 data");
            }
        }
        println!("💾 MP3 file finalized");
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
    // MP3 encoder needs interleaved i16 samples
    let num_samples = samples.len();
    let samples_per_channel = num_samples / 2;

    let left_channel = &samples[0..samples_per_channel];
    let right_channel = &samples[samples_per_channel..num_samples];

    // Convert f32 [-1.0, 1.0] to i16 [-32768, 32767] and interleave
    let mut pcm_data = Vec::with_capacity(num_samples);
    for i in 0..samples_per_channel {
        let left_i16 = (left_channel[i].clamp(-1.0, 1.0) * 32767.0) as i16;
        let right_i16 = (right_channel[i].clamp(-1.0, 1.0) * 32767.0) as i16;
        pcm_data.push(left_i16);
        pcm_data.push(right_i16);
    }

    // Encode to MP3
    if let Some((encoder, file)) = MP3_ENCODER.lock().unwrap().as_mut() {
        let buffer_size = pcm_data.len() * 5 / 4 + 7200; // LAME recommended buffer size
        let mut mp3_buffer: Vec<MaybeUninit<u8>> = vec![MaybeUninit::uninit(); buffer_size];

        let input = InterleavedPcm(&pcm_data);
        match encoder.encode(input, &mut mp3_buffer) {
            Ok(encoded_size) => {
                if encoded_size > 0 {
                    let data = unsafe {
                        std::slice::from_raw_parts(mp3_buffer.as_ptr() as *const u8, encoded_size)
                    };
                    file.write_all(data).expect("Failed to write MP3 data");
                }
            }
            Err(e) => eprintln!("❌ MP3 encoding error: {:?}", e),
        }
    }    println!("🎧 Encoded {} samples ({} bytes)", num_samples, slice.len());
}

fn main() {
    // Initialize MP3 encoder
    init_mp3_encoder(OUTPUT_FILE);

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

    // Finalize MP3 file
    close_mp3_encoder();
    println!("✅ Recording saved to {}", OUTPUT_FILE);
}
