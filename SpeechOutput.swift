import AVFoundation

/// Jarvis' voice. Sentences are synthesised to PCM with AVSpeechSynthesizer.write and played through
/// the shared engine, so (1) echo cancellation knows what is being played and (2) the orb reacts to
/// the real amplitude of the audio, measured by a tap on the player node.
@MainActor
final class SpeechOutput {
    private let synth = AVSpeechSynthesizer()
    private let pipeline: AudioPipeline

    var rateMultiplier: Float = 1.0          // "habla más despacio" lowers this
    var voiceIdentifier: String?             // chosen in Ajustes

    var onStartedSpeaking: (() -> Void)?
    var onFinishedReply: (() -> Void)?

    private(set) var isSpeaking = false
    /// Every word queued for the current reply. Used to recognise our own echo.
    private(set) var replyText = ""

    private var sentences: [String] = []      // all sentences of the reply, in order
    private var nextToSynth = 0
    private var completedSentences = 0
    private var synthesizing = false
    private var pendingBuffers = 0
    private var replyClosed = false
    private var generation = 0
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init(pipeline: AudioPipeline) { self.pipeline = pipeline }

    // MARK: voice
    static func spanishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") }
            .sorted { a, b in
                func score(_ v: AVSpeechSynthesisVoice) -> Int {
                    var s = 0
                    if v.language == "es-ES" { s += 100 }
                    if v.quality == .premium { s += 30 } else if v.quality == .enhanced { s += 20 }
                    if v.gender == .male { s += 10 }
                    return s
                }
                return score(a) > score(b)
            }
    }

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Self.spanishVoices().first ?? AVSpeechSynthesisVoice(language: "es-ES")
    }

    // MARK: reply lifecycle
    /// Start a new reply (cancels anything still playing).
    func beginReply() {
        interrupt()
        replyText = ""
        sentences = []
        nextToSynth = 0
        completedSentences = 0
        replyClosed = false
    }

    func enqueue(_ sentence: String) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        sentences.append(s)
        replyText += " " + s
        pump()
    }

    /// No more text will arrive for this reply.
    func closeReply() {
        replyClosed = true
        checkFinished()
    }

    /// Speak a standalone line (greeting, confirmations, repeats).
    func say(_ text: String) {
        beginReply()
        for s in SentenceSplitter.split(text) { enqueue(s) }
        closeReply()
    }

    /// Sentences that were cut off by an interruption — for "continúa".
    func unspokenRemainder() -> [String] {
        guard completedSentences < sentences.count else { return [] }
        return Array(sentences[completedSentences...])
    }

    /// Barge-in: stop immediately.
    func interrupt() {
        generation += 1
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        pipeline.player.stop()
        synthesizing = false
        pendingBuffers = 0
        if isSpeaking { isSpeaking = false }
    }

    // MARK: synthesis
    private func pump() {
        guard !synthesizing, nextToSynth < sentences.count, pipeline.isRunning else { return }
        let index = nextToSynth
        nextToSynth += 1
        synthesizing = true
        let gen = generation

        let u = AVSpeechUtterance(string: sentences[index])
        u.voice = currentVoice()
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.02 * rateMultiplier)
        u.pitchMultiplier = 0.94
        u.postUtteranceDelay = 0.04

        synth.write(u) { [weak self] buffer in
            let pcm = buffer as? AVAudioPCMBuffer
            let isEnd = pcm == nil || pcm!.frameLength == 0
            let converted = isEnd ? nil : self?.convert(pcm!)
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                if isEnd {
                    self.scheduleEndMarker(sentence: index, gen: gen)
                    self.synthesizing = false
                    self.pump()
                } else if let converted {
                    self.schedule(converted, gen: gen)
                }
            }
        }
    }

    /// Runs on the synthesiser's thread.
    nonisolated private func convert(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Converter is created lazily per source format; accessed only from the synth callback thread.
        let target = pipeline.playerFormat
        if src.format == target { return src }
        let conv: AVAudioConverter
        if let c = ConverterCache.shared.converter, ConverterCache.shared.source == src.format {
            conv = c
        } else {
            guard let c = AVAudioConverter(from: src.format, to: target) else { return nil }
            ConverterCache.shared.converter = c
            ConverterCache.shared.source = src.format
            conv = c
        }
        let ratio = target.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, gen: Int) {
        pendingBuffers += 1
        pipeline.player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.pendingBuffers -= 1
                self.checkFinished()
            }
        }
        if !pipeline.player.isPlaying { pipeline.player.play() }
        if !isSpeaking { isSpeaking = true; onStartedSpeaking?() }
    }

    /// An empty marker scheduled after a sentence's audio so we know when it has really been heard.
    private func scheduleEndMarker(sentence index: Int, gen: Int) {
        guard let marker = AVAudioPCMBuffer(pcmFormat: pipeline.playerFormat, frameCapacity: 1) else { return }
        marker.frameLength = 1
        pendingBuffers += 1
        pipeline.player.scheduleBuffer(marker) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.pendingBuffers -= 1
                self.completedSentences = max(self.completedSentences, index + 1)
                self.checkFinished()
            }
        }
        if !pipeline.player.isPlaying { pipeline.player.play() }
    }

    private func checkFinished() {
        guard replyClosed, !synthesizing, nextToSynth >= sentences.count, pendingBuffers == 0 else { return }
        isSpeaking = false
        onFinishedReply?()
    }
}

/// Holds the TTS sample-rate converter, used only from the synthesiser callback thread.
private final class ConverterCache: @unchecked Sendable {
    static let shared = ConverterCache()
    var converter: AVAudioConverter?
    var source: AVAudioFormat?
}

enum SentenceSplitter {
    /// Splits text into speakable sentences.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while case let (s, r)? = takeSentence(from: rest, force: false) { out.append(s); rest = r }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Returns the first complete sentence of a streaming buffer, or nil if none is complete yet.
    /// Long clauses are cut at a comma so the first audio starts quickly.
    static func takeSentence(from buf: Substring, force: Bool) -> (String, Substring)? {
        let enders: Set<Character> = [".", "!", "?", "…", ";", ":"]
        var idx = buf.startIndex
        var lastComma: String.Index?
        var count = 0
        while idx < buf.endIndex {
            let c = buf[idx]
            count += 1
            let next = buf.index(after: idx)
            if enders.contains(c) && (next == buf.endIndex ? force : buf[next].isWhitespace) {
                let s = String(buf[..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.count >= 2 { return (s, buf[next...]) }
            }
            if c == "," { lastComma = idx }
            if count > 160, let lc = lastComma {
                let n = buf.index(after: lc)
                return (String(buf[..<n]).trimmingCharacters(in: .whitespacesAndNewlines), buf[n...])
            }
            idx = next
        }
        return nil
    }
}
