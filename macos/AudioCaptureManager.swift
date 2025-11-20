import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// C callback type
typealias AudioCallback = @convention(c) (UnsafeRawPointer?, UInt32) -> Void

fileprivate var audioCallback: AudioCallback? = nil

@_cdecl("set_audio_callback")
public func set_audio_callback(_ cb: UnsafeRawPointer?) {
    if let cb = cb {
        let typed = unsafeBitCast(cb, to: AudioCallback.self)
        audioCallback = typed
        print("🔗 Audio callback set")
    } else {
        audioCallback = nil
        print("🔗 Audio callback cleared")
    }
}

@_cdecl("start_audio_recording")
public func start_audio_recording() {
    AudioCaptureManager.shared.startRecording()
}

@_cdecl("stop_audio_recording")
public func stop_audio_recording() {
    AudioCaptureManager.shared.stopRecording()
}

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    public static let shared = AudioCaptureManager()
    private var stream: SCStream?
    private var isRecording = false
    private let audioQueue = DispatchQueue(label: "AudioQueue")

    public func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        audioQueue.async {
            Task {
                await self.startCapture()
            }
        }
    }

    public func stopRecording() {
        audioQueue.async {
            Task {
                do {
                    try await self.stream?.stopCapture()
                    self.isRecording = false
                    print("🛑 Audio streaming stopped.")
                } catch {
                    print("❌ Stop error: \(error)")
                }
            }
        }
    }

    private func startCapture() async {
        print("🎙️ Starting system audio capture…")
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                print("❌ No display found")
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.stream = stream
            print("✅ Audio streaming started.")
        } catch {
            print("❌ Failed to start capture: \(error)")
        }
    }

    // SCStreamOutput delegate
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, isRecording else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        if status == noErr, let dataPointer = dataPointer, totalLength > 0 {
            if let cb = audioCallback {
                let rawPtr = UnsafeRawPointer(dataPointer)
                cb(rawPtr, UInt32(totalLength))
            }
        }
    }
}
