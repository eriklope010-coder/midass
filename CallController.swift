import AVFoundation
import UIKit

/// The continuous voice call: listen → understand → act → speak → listen, until the user hangs up.
@MainActor
final class CallController: ObservableObject {
    enum State: Equatable {
        case idle, starting, listening, userSpeaking, thinking, executing, speaking, paused(String), error(String)
        var label: String {
            switch self {
            case .idle: return ""
            case .starting: return "CONECTANDO"
            case .listening: return "TE ESCUCHO"
            case .userSpeaking: return "TE ESCUCHO"
            case .thinking: return "PENSANDO"
            case .executing: return "EJECUTANDO"
            case .speaking: return "HABLANDO"
            case .paused: return "EN PAUSA"
            case .error: return "ERROR"
            }
        }
    }
    struct Line: Identifiable { let id = UUID(); let who: Who; var text: String; enum Who { case user, jarvis, system } }

    @Published private(set) var state: State = .idle
    @Published private(set) var inCall = false
    @Published private(set) var micLive = false            // true only while the recogniser is really listening
    @Published private(set) var lines: [Line] = []
    @Published private(set) var partial = ""
    @Published private(set) var callStart = Date()
    @Published private(set) var translateFrom: String?
    @Published private(set) var lastSources: [JarvisAPI.Source] = []
    let levels = LevelMeter()

    let memory: MemoryStore
    private let pipeline = AudioPipeline()
    private lazy var voice = SpeechOutput(pipeline: pipeline)
    private let ears = SpeechInput()

    private var history: [JarvisAPI.Message] = []
    private var lastReply = ""
    private var turnTask: Task<Void, Never>?
    private var interruptedRemainder: [String] = []
    private var greetIndex = -1
    private var observers: [NSObjectProtocol] = []

    init(memory: MemoryStore) {
        self.memory = memory
        wireAudio()
        observeSession()
    }

    // MARK: - Call lifecycle

    func startCall() async {
        guard !inCall else { return }
        inCall = true
        state = .starting
        lines = []; history = []; partial = ""; lastSources = []; interruptedRemainder = []
        callStart = Date()

        // 1. Permissions — never show "listening" without a real, authorised microphone.
        let micOK = await AVAudioApplication.requestRecordPermission()
        let speechOK = await SpeechInput.requestAuthorization()
        guard micOK, speechOK else {
            fail(micOK ? "Sin permiso de reconocimiento de voz. Actívalo en Ajustes › Jarvis." : "Sin permiso de micrófono. Actívalo en Ajustes › Jarvis.")
            return
        }
        // 2. Audio session for a two-way voice conversation (echo cancellation via .voiceChat).
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            try pipeline.start()
        } catch {
            fail("No pude abrir el audio: \(error.localizedDescription)")
            return
        }
        applyVoiceSettings()
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.object(forKey: Settings.keepAwakeKey) as? Bool ?? true

        // 3. Listen from the first moment (the user can talk over the greeting).
        ears.start(locale: "es-ES")
        say(nextGreeting())
    }

    func endCall() {
        guard inCall else { return }
        turnTask?.cancel(); turnTask = nil
        voice.interrupt()
        ears.stop()
        pipeline.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIApplication.shared.isIdleTimerDisabled = false
        inCall = false
        micLive = false
        translateFrom = nil
        state = .idle
        levels.reset()
    }

    /// Tap on the orb: interrupt Jarvis.
    func tapOrb() {
        if voice.isSpeaking || turnTask != nil { interrupt(); }
    }

    // MARK: - Wiring

    private func wireAudio() {
        // These run on the audio thread: capture only thread-safe objects, never self.
        let ears = self.ears, levels = self.levels
        pipeline.onInputBuffer = { b in ears.append(b) }
        pipeline.onInputLevel = { db in ears.level(db); levels.pushInput(db) }
        pipeline.onOutputLevel = { v in levels.pushOutput(v) }
        pipeline.onConfigurationChange = { [weak self] in self?.recoverAudio(reason: "cambio de audio") }

        ears.onStatusChange = { [weak self] st in
            guard let self else { return }
            self.micLive = (st == .listening)
            if case .unavailable(let msg) = st { self.addLine(.system, msg) }
            if st == .listening, self.state == .starting { self.state = .listening }
        }
        ears.onVoiceActivity = { [weak self] active in
            guard let self, self.inCall else { return }
            if active, self.state == .listening { self.state = .userSpeaking }
            if !active, self.state == .userSpeaking, self.partial.isEmpty { self.state = .listening }
        }
        ears.onPartial = { [weak self] text in self?.handlePartial(text) }
        ears.onUtterance = { [weak self] text in self?.handleUtterance(text) }

        voice.onStartedSpeaking = { [weak self] in
            guard let self, self.inCall else { return }
            self.state = .speaking
        }
        voice.onFinishedReply = { [weak self] in
            guard let self, self.inCall, self.turnTask == nil else { return }
            if self.state == .speaking || self.state == .executing || self.state == .thinking {
                self.state = self.micLive ? .listening : .error("El micrófono dejó de escuchar.")
            }
        }
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in self?.handleInterruption(type, info: n.userInfo) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverAudio(reason: "reinicio del sistema de audio") }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, info: [AnyHashable: Any]?) {
        guard inCall else { return }
        switch type {
        case .began:
            // A phone call, Siri, an alarm… took the audio. Stop honestly.
            turnTask?.cancel(); turnTask = nil
            voice.interrupt()
            ears.suspended = true
            ears.stop()
            micLive = false
            state = .paused("Audio ocupado por otra app")
        case .ended:
            ears.suspended = false
            recoverAudio(reason: "fin de la interrupción")
        @unknown default: break
        }
    }

    private var lastRecovery = Date.distantPast
    private func recoverAudio(reason: String) {
        guard inCall, !ears.suspended else { return }
        // Engine restarts themselves emit configuration changes: debounce to avoid a restart loop.
        guard Date().timeIntervalSince(lastRecovery) > 2, Date().timeIntervalSince(pipeline.startedAt) > 1.5 || reason == "reintento manual" else { return }
        lastRecovery = Date()
        turnTask?.cancel(); turnTask = nil
        voice.interrupt()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try pipeline.restart()
            ears.stop()
            ears.start(locale: translateFrom ?? "es-ES")
            state = micLive ? .listening : .paused("El reconocimiento de voz no está disponible ahora.")
        } catch {
            micLive = false
            state = .paused("No pude recuperar el micrófono. Toca para reintentar.")
        }
    }

    func retryAudio() { recoverAudio(reason: "reintento manual") }

    // MARK: - Listening

    private func handlePartial(_ text: String) {
        guard inCall else { return }
        // While Jarvis talks, decide: barge-in by the user, or our own echo leaking through?
        if voice.isSpeaking {
            if LocalCommands.isStopPhrase(text) || (wordCount(text) >= 3 && !isEcho(text)) {
                interrupt()
                partial = text
                state = .userSpeaking
            } else if isEcho(text) {
                ears.discardCurrent()   // never treat Jarvis' own voice as a command
            }
            return
        }
        partial = text
        if state == .listening { state = .userSpeaking }
    }

    private func handleUtterance(_ raw: String) {
        guard inCall else { return }
        partial = ""
        if voice.isSpeaking && isEcho(raw) { return }
        let text = LocalCommands.stripWakeWord(raw)
        guard !text.isEmpty else {
            // Just "Jarvis": acknowledge and keep listening.
            if !voice.isSpeaking { say(["¿Sí?", "Dime.", "Aquí estoy."].randomElement()!) }
            return
        }
        addLine(.user, raw)

        if let cmd = LocalCommands.parse(text) {
            runLocal(cmd)
            return
        }
        sendTurn(text)
    }

    private func interrupt() {
        interruptedRemainder = voice.unspokenRemainder()
        voice.interrupt()
        turnTask?.cancel(); turnTask = nil
        state = micLive ? .listening : state
    }

    // MARK: - Local control phrases (instant, no network)

    private func runLocal(_ cmd: LocalCommands.Command) {
        switch cmd {
        case .stop:
            interrupt()
        case .repeatLast:
            say(lastReply.isEmpty ? "Todavía no he dicho nada que repetir." : lastReply, record: false)
        case .slower:
            let r = max(0.75, voice.rateMultiplier - 0.08); voice.rateMultiplier = r
            UserDefaults.standard.set(r, forKey: Settings.rateKey)
            say("Vale, más despacio.", record: false)
        case .faster:
            let r = min(1.3, voice.rateMultiplier + 0.08); voice.rateMultiplier = r
            UserDefaults.standard.set(r, forKey: Settings.rateKey)
            say("Venga, más ligero.", record: false)
        case .continueSpeaking:
            if interruptedRemainder.isEmpty { sendTurn("Continúa.") }
            else { say(interruptedRemainder.joined(separator: " "), record: false); interruptedRemainder = [] }
        case .hangUp:
            say("Hasta luego.", record: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.endCall() }
        case .openApp(let app):
            Task { await self.openApp(app, announce: true) }
        }
    }

    // MARK: - AI turn

    private func sendTurn(_ text: String) {
        turnTask?.cancel()
        voice.interrupt()
        history.append(.init(role: "user", content: text))
        guard let api = JarvisAPI.fromSettings() else {
            fail(JarvisAPI.APIError.notConfigured.localizedDescription, keepCall: true)
            return
        }
        state = .thinking
        let request = JarvisAPI.TurnRequest(
            messages: Array(history.suffix(40)),
            memories: memory.forPrompt(),
            mode: UserDefaults.standard.string(forKey: Settings.modeKey) ?? "normal",
            translateFrom: translateFrom,
            now: ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime]),
            timezone: TimeZone.current.identifier,
            name: UserDefaults.standard.string(forKey: Settings.nameKey) ?? ""
        )
        let lineIndex = addLine(.jarvis, "")
        voice.beginReply()

        turnTask = Task { [weak self] in
            guard let self else { return }
            var buffer = Substring("")
            var spoken = ""
            var actions: [JarvisAPI.Action] = []
            do {
                for try await ev in api.stream(request) {
                    if Task.isCancelled { return }
                    switch ev {
                    case .text(let d):
                        spoken += d
                        self.updateLine(lineIndex, spoken)
                        buffer += d
                        while case let (sentence, rest)? = SentenceSplitter.takeSentence(from: buffer, force: false) {
                            self.voice.enqueue(sentence); buffer = rest
                        }
                    case .searching(let q):
                        if !self.voice.isSpeaking { self.state = .executing }
                        self.addLine(.system, q.isEmpty ? "Buscando en internet…" : "Buscando: \(q)")
                    case .sources(let s):
                        self.lastSources = s
                    case .action(let a):
                        actions.append(a)
                    case .failure(let msg):
                        self.addLine(.system, msg)
                    case .done:
                        break
                    }
                }
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? "Se perdió la conexión."
                self.voice.enqueue("Perdona, \(msg.prefix(1).lowercased() + msg.dropFirst())")
                self.addLine(.system, msg)
            }
            if Task.isCancelled { return }
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { self.voice.enqueue(tail) }

            // Execute actions for real, then say truthfully what happened.
            var outcomes: [String] = []
            if !actions.isEmpty {
                if !self.voice.isSpeaking { self.state = .executing }
                for a in actions {
                    if Task.isCancelled { return }
                    if let o = await self.execute(a) { outcomes.append(o) }
                }
            }
            let spokenOutcomes = outcomes.filter { !$0.hasPrefix("[") }
            for o in spokenOutcomes { self.voice.enqueue(o) }
            if spoken.isEmpty && spokenOutcomes.isEmpty && actions.isEmpty { self.voice.enqueue("No me ha llegado respuesta. ¿Me lo repites?") }

            let record = ([spoken] + outcomes).filter { !$0.isEmpty }.joined(separator: " ")
            self.lastReply = ([spoken] + spokenOutcomes).filter { !$0.isEmpty }.joined(separator: " ")
            self.history.append(.init(role: "assistant", content: record.isEmpty ? "(sin respuesta)" : record))
            if !spokenOutcomes.isEmpty { self.updateLine(lineIndex, self.lastReply) }
            self.turnTask = nil
            self.voice.closeReply()
        }
    }

    /// Runs a tool call. Returns a spoken confirmation, or "[...]" for a silent note kept in the history.
    private func execute(_ a: JarvisAPI.Action) async -> String? {
        switch a.name {
        case "open_app":
            guard let id = a.input["app"] as? String, let app = MidasApp.find(id) else { return "No conozco esa aplicación." }
            return await openApp(app, announce: false)
        case "play_music":
            let q = (a.input["query"] as? String) ?? "música"
            switch await AppLauncher.spotifySearch(q) {
            case .openedApp: return "Te he abierto Spotify buscando \(q). Dale al play; Spotify no me deja arrancarlo yo."
            case .openedWeb: return "No encuentro Spotify instalado; te he abierto la búsqueda en la web."
            case .failed: return "No he podido abrir Spotify."
            }
        case "add_reminder":
            let title = (a.input["title"] as? String) ?? "Recordatorio"
            switch await RemindersService.add(title: title, dueISO: a.input["due_iso"] as? String) {
            case .created(let due):
                if let due { return "Recordatorio creado para \(due.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))." }
                return "Recordatorio creado."
            case .denied: return "No tengo permiso para Recordatorios. Puedes darlo en Ajustes, Jarvis."
            case .failed(let e): return "No he podido crear el recordatorio: \(e)"
            }
        case "remember":
            let ok = memory.add(kind: (a.input["kind"] as? String) ?? "dato", text: (a.input["text"] as? String) ?? "", replacing: a.input["replaces_id"] as? String)
            if ok { addLine(.system, "Recordado: \((a.input["text"] as? String) ?? "")") }
            return ok ? "[memoria guardada]" : "[memoria desactivada: no se guardó]"
        case "forget":
            if let id = a.input["id"] as? String { memory.delete(id: id); addLine(.system, "Recuerdo borrado.") }
            return "[recuerdo borrado]"
        case "set_translation":
            let loc = (a.input["source_locale"] as? String) ?? "off"
            if loc == "off" || loc.hasPrefix("es") {
                translateFrom = nil; ears.setLocale("es-ES")
                return "Modo intérprete desactivado."
            }
            translateFrom = loc; ears.setLocale(loc)
            if case .unavailable = ears.status { translateFrom = nil; ears.setLocale("es-ES"); return "Este iPhone no reconoce ese idioma ahora mismo." }
            return "Modo intérprete activado. Traduzco lo que oiga."
        default:
            return "[acción desconocida \(a.name)]"
        }
    }

    @discardableResult
    private func openApp(_ app: MidasApp, announce: Bool) async -> String {
        let r = await AppLauncher.open(app)
        let msg: String
        switch r {
        case .openedApp: msg = announce ? "\(app.name)." : ""
        case .openedWeb: msg = "No tienes \(app.name) instalada; te he abierto la web."
        case .failed: msg = "No he podido abrir \(app.name)."
        }
        if r == .openedApp { addLine(.system, "\(app.name) abierta. Sigo escuchando.") }
        if announce, !msg.isEmpty { say(msg, record: false) }
        return msg.isEmpty ? "[\(app.name) abierta]" : msg
    }

    // MARK: - Helpers

    private func say(_ text: String, record: Bool = true) {
        if record { lastReply = text; addLine(.jarvis, text) }
        voice.say(text)
    }

    private func fail(_ msg: String, keepCall: Bool = false) {
        addLine(.system, msg)
        state = .error(msg)
        if keepCall { voice.say(msg) } else { endCallKeepingError(msg) }
    }

    private func endCallKeepingError(_ msg: String) {
        ears.stop(); pipeline.stop(); micLive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        inCall = false
        state = .error(msg)
    }

    @discardableResult
    private func addLine(_ who: Line.Who, _ text: String) -> Int {
        lines.append(Line(who: who, text: text))
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        return lines.count - 1
    }
    private func updateLine(_ i: Int, _ text: String) { if lines.indices.contains(i) { lines[i].text = text } }

    private func applyVoiceSettings() {
        voice.voiceIdentifier = UserDefaults.standard.string(forKey: Settings.voiceKey)
        let r = UserDefaults.standard.double(forKey: Settings.rateKey)
        voice.rateMultiplier = r > 0 ? Float(r) : 1.0
    }

    private func nextGreeting() -> String {
        let g = ["Dime, ¿qué pasa?", "¿Qué necesitas?", "A tu disposición.", "Aquí estoy.", "Cuéntame.", "¿Qué se te ofrece?", "Venga, te escucho."]
        var i = Int.random(in: 0..<g.count)
        if i == greetIndex { i = (i + 1) % g.count }
        greetIndex = i
        let h = Calendar.current.component(.hour, from: Date())
        let name = UserDefaults.standard.string(forKey: Settings.nameKey).map { $0.isEmpty ? "" : ", \($0)" } ?? ""
        if Bool.random() {
            let pre = h < 6 ? "¿Tú no duermes\(name)? " : h < 13 ? "Buenos días\(name). " : h < 21 ? "Buenas tardes\(name). " : "Buenas noches\(name). "
            return pre + g[i]
        }
        return g[i]
    }

    private func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// True when most words just heard are words Jarvis is currently saying (speaker leaking into the mic).
    private func isEcho(_ heard: String) -> Bool {
        let said = Set(LocalCommands.words(voice.replyText))
        let h = LocalCommands.words(heard)
        guard !h.isEmpty, !said.isEmpty else { return false }
        let overlap = h.filter { said.contains($0) }.count
        return Double(overlap) / Double(h.count) >= 0.6
    }
}

// MARK: - Level meter (throttled, drives the orb)

final class LevelMeter: ObservableObject {
    @Published var input: Float = 0     // 0…1, user voice
    @Published var output: Float = 0    // 0…1, Jarvis' real voice amplitude
    private var lastPublish = Date.distantPast
    private var rawIn: Float = 0, rawOut: Float = 0
    private let lock = NSLock()

    func pushInput(_ db: Float) {
        let v = max(0, min(1, (db + 55) / 40))
        lock.lock(); rawIn = max(v, rawIn * 0.85); lock.unlock(); publish()
    }
    func pushOutput(_ rms: Float) {
        let v = max(0, min(1, rms * 6))
        lock.lock(); rawOut = max(v, rawOut * 0.8); lock.unlock(); publish()
    }
    func reset() { DispatchQueue.main.async { self.input = 0; self.output = 0 } }
    private func publish() {
        let now = Date()
        lock.lock()
        guard now.timeIntervalSince(lastPublish) > 1.0 / 30 else { lock.unlock(); return }
        lastPublish = now
        let i = rawIn, o = rawOut
        lock.unlock()
        DispatchQueue.main.async { self.input = i; self.output = o }
    }
}
