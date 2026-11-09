import AVFoundation
import Speech

/// Continuous speech recognition with voice-activity detection and end-of-turn detection.
/// Audio arrives from AudioPipeline's microphone tap; this class never touches the audio session.
@MainActor
final class SpeechInput {
    enum Status: Equatable { case stopped, listening, unavailable(String) }

    private(set) var status: Status = .stopped
    private(set) var localeID = "es-ES"

    /// Live transcript of the current utterance.
    var onPartial: ((String) -> Void)?
    /// The user finished a turn (silence detected after speech).
    var onUtterance: ((String) -> Void)?
    /// User voice energy started / stopped (VAD), independent of the recogniser.
    var onVoiceActivity: ((Bool) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private let box = RequestBox()

    // VAD / endpointing
    private var noiseFloor: Float = -60
    private var voiceActive = false
    private var lastVoiceAt = Date.distantPast
    private var lastPartialAt = Date.distantPast
    private var currentText = ""
    private var taskStartedAt = Date()
    private var endpointTimer: Timer?

    /// Seconds of silence that end a turn. Longer when the sentence is clearly unfinished.
    var baseSilence: TimeInterval = 0.85
    var suspended = false   // true while an interruption (phone call, Siri) owns the audio

    // MARK: permissions
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    // MARK: lifecycle
    func start(locale: String? = nil) {
        if let locale { localeID = locale }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        guard let recognizer, recognizer.isAvailable else {
            setStatus(.unavailable("El reconocimiento de voz para \(localeID) no está disponible ahora."))
            return
        }
        startTask()
        endpointTimer?.invalidate()
        endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEndpoint() }
        }
    }

    func stop() {
        endpointTimer?.invalidate(); endpointTimer = nil
        cancelTask()
        setStatus(.stopped)
    }

    /// Change language (interpreter mode).
    func setLocale(_ id: String) {
        guard id != localeID else { return }
        stop()
        start(locale: id)
    }

    /// Throw away what has been heard so far (e.g. it was Jarvis' own echo) and keep listening.
    func discardCurrent() {
        guard status == .listening else { return }
        cancelTask()
        startTask()
    }

    /// Called from the audio thread for every microphone buffer.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) { box.append(buffer) }

    /// Called from the audio thread with the microphone level.
    nonisolated func level(_ db: Float) {
        Task { @MainActor [weak self] in self?.updateVAD(db) }
    }

    // MARK: internals
    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatusChange?(s)
    }

    private func startTask() {
        guard let recognizer, !suspended else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(iOS 16.0, *) { req.addsPunctuation = true }
        // On-device: lower latency, works offline, no 1-minute server limit, audio stays on the phone.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        box.set(req)
        currentText = ""
        taskStartedAt = Date()
        let started = taskStartedAt
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.taskStartedAt == started else { return }   // stale task
                if let text, !text.isEmpty, text != self.currentText {
                    self.currentText = text
                    self.lastPartialAt = Date()
                    self.onPartial?(text)
                }
                if isFinal { self.finishTurn() }
                else if error != nil {
                    // "No speech detected", recogniser timeouts, etc.: deliver what we have, then restart.
                    if !self.currentText.isEmpty { self.finishTurn() } else { self.restartSoon() }
                }
            }
        }
        setStatus(.listening)
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        box.set(nil)
        currentText = ""
    }

    private func restartSoon() {
        guard status == .listening || status == .stopped, endpointTimer != nil else { return }
        cancelTask()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.endpointTimer != nil, !self.suspended else { return }
            self.startTask()
        }
    }

    private func updateVAD(_ db: Float) {
        // Adaptive noise floor: falls quickly, rises slowly — robust to background noise.
        if db < noiseFloor { noiseFloor = noiseFloor * 0.9 + db * 0.1 }
        else { noiseFloor = noiseFloor * 0.998 + db * 0.002 }
        noiseFloor = min(max(noiseFloor, -75), -30)
        let threshold = max(noiseFloor + 12, -52)
        let speaking = db > threshold
        if speaking { lastVoiceAt = Date() }
        let active = Date().timeIntervalSince(lastVoiceAt) < 0.35
        if active != voiceActive { voiceActive = active; onVoiceActivity?(active) }
    }

    private func requiredSilence(for text: String) -> TimeInterval {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let unfinished = ["y", "o", "pero", "que", "porque", "entonces", "pues", "como", "de", "a", "en", "con", "para", "el", "la", "los", "las", "un", "una", "mi", "tu", "si", "cuando", "eh", "em", "mmm"]
        if t.hasSuffix("...") || t.hasSuffix(",") { return baseSilence * 2 }
        if let last = t.split(separator: " ").last, unfinished.contains(String(last)) { return baseSilence * 2.1 }
        return baseSilence
    }

    private func checkEndpoint() {
        guard status == .listening, !suspended else { return }
        let now = Date()
        if !currentText.isEmpty {
            let quietFor = min(now.timeIntervalSince(lastPartialAt), now.timeIntervalSince(lastVoiceAt))
            if quietFor >= requiredSilence(for: currentText) { finishTurn() }
        } else if now.timeIntervalSince(taskStartedAt) > 50 {
            restartSoon()   // keep tasks fresh during long silences
        }
    }

    private func finishTurn() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelTask()
        if !text.isEmpty { onUtterance?(text) }
        if endpointTimer != nil && !suspended { startTask() }
    }
}

/// Thread-safe holder for the active recognition request (audio thread appends, main thread swaps).
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); let old = request; request = r; lock.unlock()
        old?.endAudio()
    }
    func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(b)
    }
}
