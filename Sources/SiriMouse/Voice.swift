import AppKit
import AVFoundation
import Speech

/// What the Siri button does. Audio always comes from the Mac's microphone: the 1st-gen
/// remote's own microphone stream is not delivered to apps by macOS.
final class Voice {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var transcript = ""
    private var isListening = false

    func siriButton(pressed: Bool) {
        switch Settings.shared.siriAction {
        case .siri:
            if pressed { openSiri() }
        case .dictation:
            pressed ? startDictation() : stopDictation()
        case .none:
            break
        }
    }

    // MARK: Siri

    private func openSiri() {
        // Launching Siri.app is how the Dock / Launchpad icon invokes Siri; it starts listening.
        let url = URL(fileURLWithPath: "/System/Applications/Siri.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.info("Could not open Siri: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    HUD.shared.show("Enable Siri in System Settings", symbol: "exclamationmark.triangle", duration: 2.5)
                }
            }
        }
    }

    // MARK: Dictation (hold to talk, types into the frontmost app)

    private func startDictation() {
        guard !isListening else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    guard status == .authorized, micGranted else {
                        HUD.shared.show("Allow Microphone & Speech Recognition", symbol: "mic.slash", duration: 2.5)
                        return
                    }
                    self.beginListening()
                }
            }
        }
    }

    private func beginListening() {
        guard !isListening else { return }
        let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            HUD.shared.show("Speech recognition unavailable", symbol: "mic.slash", duration: 2)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.info("Audio engine failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }

        transcript = ""
        isListening = true
        self.recognizer = recognizer
        self.request = request
        HUD.shared.show("Listening…", symbol: "mic.fill", duration: nil)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.deliver() }
                } else if error != nil {
                    self.deliver()
                }
            }
        }
    }

    private func stopDictation() {
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        HUD.shared.show("Transcribing…", symbol: "waveform", duration: nil)
        // If the recognizer never sends a final result, type what we have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.deliver() }
    }

    private func deliver() {
        guard task != nil, !isListening else { return }
        task?.cancel()
        task = nil
        request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        if text.isEmpty {
            HUD.shared.hide()
        } else {
            EventPoster.type(text)
            HUD.shared.show("Typed \(text.count) characters", symbol: "keyboard", duration: 1.2)
        }
    }
}
