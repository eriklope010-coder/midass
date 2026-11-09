import AVFoundation

/// One AVAudioEngine shared by microphone input and Jarvis' voice output.
/// Voice processing (Apple's echo cancellation + noise suppression) is enabled on the input node,
/// so the microphone hears the user, not Jarvis' own voice coming out of the speaker.
final class AudioPipeline {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Format every TTS buffer is converted to before scheduling.
    let playerFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// Called on the audio render thread with every microphone buffer.
    var onInputBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Microphone level in dBFS (about -80…0), audio thread.
    var onInputLevel: ((Float) -> Void)?
    /// Level of Jarvis' voice actually being played (0…1), audio thread.
    var onOutputLevel: ((Float) -> Void)?

    private(set) var isRunning = false
    private(set) var startedAt = Date.distantPast
    private var configObserver: NSObjectProtocol?
    var onConfigurationChange: (() -> Void)?

    init() {
        engine.attach(player)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
    }

    deinit { if let o = configObserver { NotificationCenter.default.removeObserver(o) } }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        // Must be set before the engine starts. Gives AEC so barge-in works on the loudspeaker.
        try input.setVoiceProcessingEnabled(true)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Midas", code: 1, userInfo: [NSLocalizedDescriptionKey: "No hay entrada de micrófono disponible."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onInputBuffer?(buffer)
            self.onInputLevel?(AudioPipeline.dbfs(buffer))
        }
        player.removeTap(onBus: 0)
        player.installTap(onBus: 0, bufferSize: 1024, format: playerFormat) { [weak self] buffer, _ in
            self?.onOutputLevel?(AudioPipeline.rms(buffer))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        startedAt = Date()
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isRunning = false
    }

    /// Restart after a route change or an interruption.
    func restart() throws {
        stop()
        try start()
    }

    // MARK: levels
    static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0], b.frameLength > 0 else { return 0 }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        return sqrt(sum / Float(n))
    }

    static func dbfs(_ b: AVAudioPCMBuffer) -> Float {
        let r = rms(b)
        return r > 0 ? max(-80, 20 * log10(r)) : -80
    }
}
