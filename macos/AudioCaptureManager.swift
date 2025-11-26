import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var micRecorder: AVAudioRecorder?
    private var isRecording = false
    private var window: NSWindow?

    private var systemAssetWriter: AVAssetWriter?
    private var systemAssetInput: AVAssetWriterInput?
    private var systemURL: URL?
    private var micURL: URL?

    public func startRecording() {
        Task { await self.start() }
    }

    public func stopRecording() {
        stop()
    }

    @MainActor
    private func start() async {
        guard !isRecording else { return }
        print("🎙️ Starting capture…")

        do {
            // Invisible AppKit window
            if window == nil {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                 styleMask: [],
                                 backing: .buffered,
                                 defer: false)
                w.alphaValue = 0
                w.isOpaque = false
                w.level = .mainMenu + 1
                w.makeKeyAndOrderFront(nil)
                window = w
            }

            // System audio capture
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                print("❌ No display found")
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            stream = SCStream(filter: filter, configuration: config, delegate: self)

            systemURL = FileManager.default.temporaryDirectory.appendingPathComponent("sys_tmp.m4a")
            systemAssetWriter = try AVAssetWriter(outputURL: systemURL!, fileType: .m4a)
            let systemSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            systemAssetInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
            systemAssetInput?.expectsMediaDataInRealTime = true
            systemAssetWriter?.add(systemAssetInput!)
            systemAssetWriter?.startWriting()
            systemAssetWriter?.startSession(atSourceTime: .zero)

            // Mic capture
            micURL = FileManager.default.temporaryDirectory.appendingPathComponent("mic_tmp.caf")
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            micRecorder = try AVAudioRecorder(url: micURL!, settings: micSettings)
            micRecorder?.record()
            print("🎤 Microphone recording started")

            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .background))
            try await stream?.startCapture()
            print("✅ System audio capture started")

            isRecording = true
        } catch {
            print("❌ Error: \(error)")
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        stream?.stopCapture()
        micRecorder?.stop()
        systemAssetInput?.markAsFinished()

        guard let writer = systemAssetWriter else { return }
        writer.finishWriting { [weak self] in
            guard let self else { return }
            print("🛑 Finished recording, merging…")
            self.mergeFiles()
        }
    }

    private func mergeFiles() {
        guard let systemURL, let micURL else { return }

        let composition = AVMutableComposition()
        do {
            let sysAsset = AVURLAsset(url: systemURL)
            let micAsset = AVURLAsset(url: micURL)

            if let sysTrack = sysAsset.tracks(withMediaType: .audio).first {
                let track = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
                try track?.insertTimeRange(CMTimeRange(start: .zero, duration: sysAsset.duration),
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

            let outputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("merged_audio.m4a")
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            let export = AVAssetExportSession(asset: composition,
                                              presetName: AVAssetExportPresetAppleM4A)!
            export.outputURL = outputURL
            export.outputFileType = .m4a
            export.exportAsynchronously {
                if export.status == .completed {
                    print("💾 Saved merged file: \(outputURL.path)")
                } else {
                    print("❌ Merge error: \(export.error?.localizedDescription ?? "unknown")")
                }
            }
        } catch {
            print("❌ Merge failed: \(error)")
        }
    }

    // SCStreamOutput callback
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType)
    {
        guard outputType == .audio, isRecording, CMSampleBufferIsValid(sampleBuffer) else { return }

        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block,
                                        atOffset: 0,
                                        lengthAtOffsetOut: nil,
                                        totalLengthOut: &length,
                                        dataPointerOut: &dataPointer)

            print("🎧 Audio buffer: \(length) bytes")
            if let cb = GLOBAL_AUDIO_CALLBACK, let dataPointer {
                cb(UnsafeRawPointer(dataPointer), UInt32(length))
            }

            if let input = systemAssetInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
}

// Rust FFI
public typealias AudioCallback = @convention(c) (UnsafeRawPointer?, UInt32) -> Void
public var GLOBAL_AUDIO_CALLBACK: AudioCallback? = nil

@_cdecl("set_audio_callback")
public func set_audio_callback(_ cb: AudioCallback?) {
    GLOBAL_AUDIO_CALLBACK = cb
}

var globalRecorder: AudioCaptureManager?

@_cdecl("start_audio_recording")
public func start_audio_recording() {
    globalRecorder = AudioCaptureManager()
    globalRecorder?.startRecording()
}

@_cdecl("stop_audio_recording")
public func stop_audio_recording() {
    globalRecorder?.stopRecording()
    globalRecorder = nil
}
