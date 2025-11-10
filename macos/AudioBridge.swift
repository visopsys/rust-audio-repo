import Foundation

@_cdecl("start_audio_recording")
public func start_audio_recording(_ path: UnsafePointer<CChar>) {
    let recorder = AudioCaptureManager()
    let swiftPath = String(cString: path)
    recorder.startRecording(swiftPath as NSString)
    globalRecorder = recorder
}

@_cdecl("stop_audio_recording")
public func stop_audio_recording() {
    globalRecorder?.stopRecording()
}

var globalRecorder: AudioCaptureManager? = nil
