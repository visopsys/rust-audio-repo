use std::slice;
use std::sync::{Mutex, OnceLock};
use std::mem::MaybeUninit;
use mp3lame_encoder::{Builder, Encoder, FlushNoGap, InterleavedPcm};

// Global encoder state
struct GlobalState {
    encoder: Encoder,
    mp3_data: Vec<u8>,
}

static STATE: OnceLock<Mutex<GlobalState>> = OnceLock::new();

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

        // Convert u8 bytes to i16 PCM samples
        // We assume the input is already Little Endian Int16 from Swift
        let pcm_data: &[i16] = unsafe {
            slice::from_raw_parts(data as *const i16, slice.len() / 2)
        };

        if let Some(mutex) = STATE.get() {
            if let Ok(mut state) = mutex.lock() {
                // Reserve enough space for worst case MP3 frame size
                let mut mp3_out_buffer = vec![MaybeUninit::uninit(); pcm_data.len()];
                let input = InterleavedPcm(pcm_data);

                match state.encoder.encode(input, &mut mp3_out_buffer) {
                    Ok(encoded_len) => {
                        if encoded_len > 0 {
                            let encoded_slice = unsafe {
                                slice::from_raw_parts(
                                    mp3_out_buffer.as_ptr() as *const u8,
                                    encoded_len
                                )
                            };
                            state.mp3_data.extend_from_slice(encoded_slice);
                        }
                    }
                    Err(e) => eprintln!("MP3 encode error: {:?}", e),
                }
            }
        }
    }
}

struct AudioRecorder {
    is_recording: bool,
}

impl AudioRecorder {
    fn new() -> Self {
        // Initialize MP3 Encoder
        let mut builder = Builder::new().expect("Create Encoder Builder");
        builder.set_num_channels(2).expect("set channels");
        builder.set_sample_rate(48000).expect("set sample rate");
        builder.set_brate(mp3lame_encoder::Bitrate::Kbps320).expect("set bitrate");
        builder.set_quality(mp3lame_encoder::Quality::Best).expect("set quality");

        let encoder = builder.build().expect("To initialize MP3 encoder");

        // Initialize global state if not already initialized
        let _ = STATE.set(Mutex::new(GlobalState {
            encoder,
            mp3_data: Vec::new(),
        }));

        AudioRecorder {
            is_recording: false,
        }
    }

    fn start_recording(&mut self) {
        if self.is_recording {
            return;
        }
        self.is_recording = true;

        unsafe { set_audio_callback(Some(on_audio)) };
        println!("🎙️ Starting recording…");
        unsafe { start_audio_recording() };
    }

    fn stop_recording(&mut self) {
        if !self.is_recording {
            return;
        }
        self.is_recording = false;

        unsafe { stop_audio_recording() };

        // Flush and save
        if let Some(mutex) = STATE.get() {
            if let Ok(mut state) = mutex.lock() {
                let mut mp3_out_buffer = vec![MaybeUninit::uninit(); 4096];
                match state.encoder.flush::<FlushNoGap>(&mut mp3_out_buffer) {
                    Ok(encoded_len) => {
                        if encoded_len > 0 {
                            let encoded_slice = unsafe {
                                slice::from_raw_parts(
                                    mp3_out_buffer.as_ptr() as *const u8,
                                    encoded_len
                                )
                            };
                            state.mp3_data.extend_from_slice(encoded_slice);
                        }

                        let path = "output.mp3";
                        std::fs::write(path, &state.mp3_data).expect("Write mp3 file");
                        println!("💾 Saved MP3 to {}", path);
                    }
                    Err(e) => eprintln!("Flush error: {:?}", e),
                }
            }
        }

        println!("🛑 Recording stopped.");
    }
}

fn main() {
    let mut recorder = AudioRecorder::new();

    recorder.start_recording();

    // Run 10 seconds
    unsafe { run_main_loop_for(10.0) };

    recorder.stop_recording();
}
