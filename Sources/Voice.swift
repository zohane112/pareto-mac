// Built-in voice: hold the shortcut and speak, let go and it runs. It uses Apple's own speech
// recognition, on this Mac when the Mac supports it. Wispr Flow works too, by typing into the
// bar like any other app.

import AVFoundation
import Speech

final class Voice: NSObject {
    static let shared = Voice()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var latest = ""
    private var finished: ((String) -> Void)?
    private(set) var listening = false

    /// Called with what's been heard so far, while listening.
    var onPartial: ((String) -> Void)?

    enum Problem: String {
        case noPermission = "Voice needs permission for the microphone and speech recognition, in System Settings › Privacy & Security."
        case noMicrophone = "No microphone found."
        case unavailable = "Speech recognition isn't available right now."
    }

    /// Asks macOS for the microphone and speech recognition, once. Calls back on the main thread.
    func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { DispatchQueue.main.async { done(false) }; return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: DispatchQueue.main.async { done(true) }
            case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
            default: DispatchQueue.main.async { done(false) }
            }
        }
    }

    /// Starts listening. Returns a problem instead when it can't.
    func start() -> Problem? {
        guard !listening else { return nil }
        guard let recognizer, recognizer.isAvailable else { return .unavailable }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return .noMicrophone }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request
        latest = ""

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return .noMicrophone
        }
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.latest = text
                    self.onPartial?(text)
                    if result.isFinal { self.finish() }
                }
            }
            if error != nil { DispatchQueue.main.async { self.finish() } }
        }
        return nil
    }

    /// Stops listening; `done` gets everything that was said (possibly empty).
    func stop(_ done: @escaping (String) -> Void) {
        guard listening else { done(latest); return }
        finished = done
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The final words arrive a moment after the audio ends; don't wait forever for them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
    }

    func cancel() {
        finished = nil
        if listening {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        cleanUp()
    }

    private func finish() {
        let done = finished
        finished = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        cleanUp()
        done?(latest)
    }

    private func cleanUp() {
        listening = false
        task = nil
        request = nil
    }
}
