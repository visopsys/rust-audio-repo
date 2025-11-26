import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

@objc public class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var isRecording = false
    private var window: NSWindow?

    // Mixing
    private let audioEngine = AVAudioEngine()
    private let ringBuffer = AudioRingBuffer(capacity: 48000 * 2 * 5) // 5 seconds buffer
    private var micConverter: AVAudioConverter?

    // System Audio Conversion
    private var audioConverter: AVAudioConverter?
    private var pcmBuffer: AVAudioPCMBuffer?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 48000,
                                             channels: 2,
                                             interleaved: true)!

    public func startRecording() {
        Task { await self.start() }
    }

    public func stopRecording() {
        stop()
    }

    @MainActor
    private func start() async {
        guard !isRecording else { return }

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

            // 1. Start Microphone Capture
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)

            // Setup Mic Converter
            micConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
                guard let self = self else { return }
                self.processMicBuffer(buffer)
            }

            try audioEngine.start()

            // 2. Start System Capture
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            stream = SCStream(filter: filter, configuration: config, delegate: self)

            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream?.startCapture()

            isRecording = true
        } catch {
            // Handle error silently or log to a file if needed
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false

        if let stream = stream {
            try? stream.removeStreamOutput(self, type: .audio)
            stream.stopCapture()
        }
        stream = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        window?.close()
        window = nil
    }

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        // Convert Mic to Target Format
        guard let converter = micConverter else { return }

        // We need an output buffer
        let frameCount = buffer.frameLength
        // Ratio might be different if sample rates differ, but let's assume close enough for buffer size estimation
        // or calculate properly:
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 100

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else { return }

        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let data = outputBuffer.int16ChannelData {
            let count = Int(outputBuffer.frameLength * targetFormat.streamDescription.pointee.mChannelsPerFrame)
            let ptr = UnsafeBufferPointer(start: data[0], count: count)
            ringBuffer.write(ptr)
        }
    }

    // SCStreamOutput callback
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType)
    {
        guard outputType == .audio, isRecording, CMSampleBufferIsValid(sampleBuffer) else { return }

        // 1. Set up converter if needed
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        if audioConverter == nil || audioConverter?.inputFormat != inputFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter = audioConverter else { return }

        // 2. Create input buffer
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(numSamples)

        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                     at: 0,
                                                     frameCount: Int32(numSamples),
                                                     into: inputBuffer.mutableAudioBufferList)

        // 3. Convert
        if pcmBuffer == nil || pcmBuffer!.frameCapacity < numSamples {
             pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(numSamples))
        }
        guard let outputBuffer = pcmBuffer else { return }

        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        // 4. Mix with Mic
        if let sysData = outputBuffer.int16ChannelData {
            let frameCount = Int(outputBuffer.frameLength)
            let channels = Int(targetFormat.streamDescription.pointee.mChannelsPerFrame)
            let totalSamples = frameCount * channels

            let sysPtr = sysData[0] // Interleaved

            // Read from Mic Ring Buffer
            var micSamples = [Int16](repeating: 0, count: totalSamples)
            let readCount = ringBuffer.read(&micSamples, count: totalSamples)

            // Mix
            for i in 0..<totalSamples {
                var mixed: Int32 = Int32(sysPtr[i])
                if i < readCount {
                    mixed += Int32(micSamples[i])
                }
                // Clamp
                if mixed > Int16.max { mixed = Int32(Int16.max) }
                if mixed < Int16.min { mixed = Int32(Int16.min) }

                sysPtr[i] = Int16(mixed)
            }

            // Send to Rust
            let byteLength = totalSamples * 2
            if let cb = GLOBAL_AUDIO_CALLBACK {
                cb(UnsafeRawPointer(sysPtr), UInt32(byteLength))
            }
        }
    }
}

class AudioRingBuffer {
    private var buffer: [Int16]
    private var writeIndex = 0
    private var readIndex = 0
    private var available = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Int16](repeating: 0, count: capacity)
    }

    func write(_ data: UnsafeBufferPointer<Int16>) {
        lock.lock()
        defer { lock.unlock() }

        let count = data.count
        for i in 0..<count {
            buffer[writeIndex] = data[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        available = min(available + count, capacity)
        if available == capacity {
            // Buffer full, push read index forward (overwrite old data)
            readIndex = (readIndex + count) % capacity
        }
    }

    func read(_ outData: inout [Int16], count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let toRead = min(count, available)
        for i in 0..<toRead {
            outData[i] = buffer[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        available -= toRead
        return toRead
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

@_cdecl("run_main_loop_for")
public func run_main_loop_for(_ seconds: Double) {
    let _ = CFRunLoopRunInMode(.defaultMode, seconds, false)
}
