import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var systemAssetWriter: AVAssetWriter?
    private var systemAssetInput: AVAssetWriterInput?
    private var isRecording = false
    private var systemURL: URL?
    private var micURL: URL?
    private var micRecorder: AVAudioRecorder?

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
        print("🎙️ Starting system + mic audio capture…")

        do {
            // 1️⃣ SCStream system audio
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                print("❌ No display found.")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false

            stream = SCStream(filter: filter, configuration: config, delegate: self)

            // 2️⃣ AVAssetWriter setup for system audio
            systemURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_system.m4a")
            systemAssetWriter = try AVAssetWriter(outputURL: systemURL!, fileType: .m4a)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]

            systemAssetInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            systemAssetInput?.expectsMediaDataInRealTime = true
            if let input = systemAssetInput, systemAssetWriter?.canAdd(input) == true {
                systemAssetWriter?.add(input)
            }

            systemAssetWriter?.startWriting()
            systemAssetWriter?.startSession(atSourceTime: .zero)

            // 3️⃣ Start microphone capture using AVAudioRecorder
            micURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_mic.caf")
            let micSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            micRecorder = try AVAudioRecorder(url: micURL!, settings: micSettings)
            micRecorder?.record()

            // 4️⃣ Start SCStream
            let audioQueue = DispatchQueue(label: "AudioQueue")
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream?.startCapture()

            isRecording = true
            print("✅ Recording started")

        } catch {
            print("❌ Error: \(error)")
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false

        // Stop SCStream
        stream?.stopCapture()
        stream = nil

        // Stop mic
        micRecorder?.stop()
        micRecorder = nil

        // Finish system audio safely
        guard let writer = systemAssetWriter else { return }
        systemAssetInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self = self,
                  let systemURL = self.systemURL,
                  let micURL = self.micURL else { return }
            print("✅ Recording finished: system=\(systemURL.path), mic=\(micURL.path)")

            // Merge must be on main thread because of NSSavePanel
            DispatchQueue.main.async {
                self.merge(systemURL: systemURL, micURL: micURL)
            }
        }
    }



    // MARK: SCStream delegate
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              isRecording,
              let input = systemAssetInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: Merge function
    private func merge(systemURL: URL, micURL: URL) {
        let composition = AVMutableComposition()
        guard
            let systemAsset = try? AVURLAsset(url: systemURL),
            let micAsset = try? AVURLAsset(url: micURL)
        else {
            print("❌ Failed to create AVAssets for merging")
            return
        }

        do {
            // System track
            if let systemTrack = systemAsset.tracks(withMediaType: .audio).first {
                let compTrack1 = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try compTrack1.insertTimeRange(CMTimeRange(start: .zero, duration: systemAsset.duration),
                                               of: systemTrack,
                                               at: .zero)
            }

            // Mic track
            if let micTrack = micAsset.tracks(withMediaType: .audio).first {
                let compTrack2 = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try compTrack2.insertTimeRange(CMTimeRange(start: .zero, duration: micAsset.duration),
                                               of: micTrack,
                                               at: .zero)
            }

            // Export final M4A
            let panel = NSSavePanel()
            panel.title = "Save Audio Recording"
            if let m4aType = UTType(filenameExtension: "m4a") {
                panel.allowedContentTypes = [m4aType]
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            panel.nameFieldStringValue = "Recording_\(formatter.string(from: Date())).m4a"

            if panel.runModal() == .OK, let destURL = panel.url {
                let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)!
                export.outputURL = destURL
                export.outputFileType = .m4a
                export.exportAsynchronously {
                    switch export.status {
                    case .completed:
                        print("💾 Final merged recording saved at: \(destURL.path)")
                        try? FileManager.default.removeItem(at: systemURL)
                        try? FileManager.default.removeItem(at: micURL)
                    case .failed, .cancelled:
                        print("❌ Failed to export final recording: \(export.error?.localizedDescription ?? "unknown")")
                    default: break
                    }
                }
            }

        } catch {
            print("❌ Error merging audio tracks: \(error)")
        }
    }
}
