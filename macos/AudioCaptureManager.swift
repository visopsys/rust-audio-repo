import Foundation
import ScreenCaptureKit
import AVFoundation

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var systemAssetWriter: AVAssetWriter?
    private var systemAssetInput: AVAssetWriterInput?
    private var isRecording = false

    private var systemURL: URL?
    private var micURL: URL?
    private var micRecorder: AVAudioRecorder?

    override public init() {}

    @objc public func startRecording() {
        Task { await start() }
    }

    @objc public func stopRecording() {
        stop()
    }

    @MainActor
    private func start() async {
        guard !isRecording else { return }

        print("🎙️ Background system + mic capture start…")

        do {
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

            // System audio temp file
            systemURL = FileManager.default.temporaryDirectory.appendingPathComponent("sys_tmp.m4a")
            systemAssetWriter = try AVAssetWriter(outputURL: systemURL!, fileType: .m4a)

            let settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ] as [String : Any]

            systemAssetInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            systemAssetInput?.expectsMediaDataInRealTime = true
            systemAssetWriter?.add(systemAssetInput!)

            systemAssetWriter?.startWriting()
            systemAssetWriter?.startSession(atSourceTime: .zero)

            // Mic audio
            micURL = FileManager.default.temporaryDirectory.appendingPathComponent("mic_tmp.caf")

            let micSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ] as [String : Any]

            micRecorder = try AVAudioRecorder(url: micURL!, settings: micSettings)
            micRecorder?.record()

            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .background))
            try await stream?.startCapture()

            isRecording = true
            print("✅ Background recording started")

        } catch {
            print("❌ Error: \(error)")
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false

        stream?.stopCapture()
        micRecorder?.stop()

        guard let writer = systemAssetWriter else { return }
        systemAssetInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self else { return }
            print("🛑 Finished background recording, merging...")

            self.mergeFiles()
        }
    }

    private func mergeFiles() {
        guard let systemURL, let micURL else { return }

        let composition = AVMutableComposition()
        do {
            let systemAsset = AVURLAsset(url: systemURL)
            let micAsset = AVURLAsset(url: micURL)

            if let sysTrack = systemAsset.tracks(withMediaType: .audio).first {
                let track = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(CMTimeRange(start: .zero, duration: systemAsset.duration),
                                           of: sysTrack,
                                           at: .zero)
            }

            if let micTrack = micAsset.tracks(withMediaType: .audio).first {
                let track = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(CMTimeRange(start: .zero, duration: micAsset.duration),
                                           of: micTrack,
                                           at: .zero)
            }

            // Background output — no UI
            let outputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("merged_audio.m4a")

            let export = AVAssetExportSession(asset: composition,
                                              presetName: AVAssetExportPresetAppleM4A)!
            export.outputURL = outputURL
            export.outputFileType = .m4a

            export.exportAsynchronously {
                if export.status == .completed {
                    print("💾 Saved merged file: \(outputURL.path)")
                } else {
                    print("❌ Export error: \(export.error?.localizedDescription ?? "unknown")")
                }
            }

        } catch {
            print("❌ Merge failed: \(error)")
        }
    }

    // Send PCM to Rust
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType)
    {
        guard
            outputType == .audio,
            isRecording,
            CMSampleBufferIsValid(sampleBuffer)
        else { return }

        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?

            CMBlockBufferGetDataPointer(block,
                                        atOffset: 0,
                                        lengthAtOffsetOut: nil,
                                        totalLengthOut: &length,
                                        dataPointerOut: &dataPointer)

            if let cb = GLOBAL_AUDIO_CALLBACK,
               let dataPointer
            {
                cb(UnsafeRawPointer(dataPointer), UInt32(length))
            }
        }
    }
}
