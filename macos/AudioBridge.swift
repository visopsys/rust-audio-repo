import Foundation

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

var globalRecorder: AudioCaptureManager? = nil
