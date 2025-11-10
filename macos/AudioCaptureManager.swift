import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var isRecording = false
    private var outputURL: URL?

    @objc public func startRecording(_ path: NSString) {
        Task {
            await start()
        }
    }

    @objc public func stopRecording() {
        stop()
    }

    @MainActor
    private func start() async {
        guard !isRecording else { return }
        print("🎙️ Starting system audio capture…")

        // Save to temporary file first
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_audio.m4a")

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

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            assetWriter = try AVAssetWriter(outputURL: outputURL!, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]

            assetWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            assetWriterInput?.expectsMediaDataInRealTime = true

            if let input = assetWriterInput, assetWriter?.canAdd(input) == true {
                assetWriter?.add(input)
            }

            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: .zero)

            let audioQueue = DispatchQueue(label: "AudioQueue")
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

            try await stream?.startCapture()
            isRecording = true

            print("✅ Recording started to temporary file.")
        } catch {
            print("❌ Error: \(error)")
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        stream?.stopCapture()
        assetWriterInput?.markAsFinished()

        assetWriter?.finishWriting { [weak self] in
            guard let self = self, let tempURL = self.outputURL else { return }
            print("✅ Recording finished: \(tempURL.path)")

            // Show save panel to user after recording stops
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.title = "Save System Audio Recording"
                panel.allowedFileTypes = ["m4a"]

                // Default name with timestamp
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                panel.nameFieldStringValue = "Recording_\(formatter.string(from: Date())).m4a"

                if panel.runModal() == .OK, let destURL = panel.url {
                    do {
                        try FileManager.default.copyItem(at: tempURL, to: destURL)
                        print("💾 Saved recording to: \(destURL.path)")
                    } catch {
                        print("❌ Failed to save file: \(error)")
                    }
                } else {
                    print("⚠️ Save canceled by user.")
                }

                // Clean up temporary file
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              isRecording,
              let input = assetWriterInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
}
