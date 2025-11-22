import Foundation

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
