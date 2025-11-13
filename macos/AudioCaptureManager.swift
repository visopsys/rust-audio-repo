import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// C callback type as a Swift function pointer (C convention)
typealias AudioCallback = @convention(c) (UnsafeRawPointer?, UInt32) -> Void

// global variable to hold the callback pointer
fileprivate var audioCallback: AudioCallback? = nil

// Exported setter so Rust can pass the callback pointer at runtime
@_cdecl("set_audio_callback")
public func set_audio_callback(_ cb: UnsafeRawPointer?) {
    if let cb = cb {
        // Convert to typed function pointer
        let typed = unsafeBitCast(cb, to: AudioCallback.self)
        audioCallback = typed
        print("🔗 audio callback set")
    } else {
        audioCallback = nil
        print("🔗 audio callback cleared")
    }
}

// Exported start/stop functions that Rust (or other C) can call
@_cdecl("start_audio_recording")
public func start_audio_recording() {
    AudioCaptureManager.shared.startRecording()
}

@_cdecl("stop_audio_recording")
public func stop_audio_recording() {
    AudioCaptureManager.shared.stopRecording()
}

// MARK: - Audio Capture Manager

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    public static let shared = AudioCaptureManager()
    private var stream: SCStream?
    private var isRecording = false

    public func startRecording() {
        Task { await start() }
    }

    public func stopRecording() {
        Task {
            do {
                try await stream?.stopCapture()
                print("🛑 Audio streaming stopped.")
                isRecording = false
            } catch {
                print("❌ Stop error: \(error)")
            }
        }
    }

    @MainActor
    private func start() async {
        guard !isRecording else { return }
        print("🎙️ Starting live system audio stream…")

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                print("❌ No display found.")
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "AudioQueue"))
            try await stream.startCapture()
            self.stream = stream
            self.isRecording = true
            print("✅ Live audio streaming started.")
        } catch {
            print("❌ Error: \(error)")
        }
    }

    // SCStreamOutput delegate:
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, isRecording else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        if status == noErr, let dataPointer = dataPointer, totalLength > 0 {
            // Call the C/registered callback with raw bytes
            if let cb = audioCallback {
                let rawPtr = UnsafeRawPointer(dataPointer)
                cb(rawPtr, UInt32(totalLength))
            }
        }
    }
}
