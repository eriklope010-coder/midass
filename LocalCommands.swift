import Foundation

/// Control phrases handled instantly on the phone (no network round-trip).
/// Everything else — including commands phrased in any other way — goes to the AI, which understands
/// intent and calls tools. This is a fast path, not a list of required phrases.
enum LocalCommands {
    enum Command: Equatable { case stop, repeatLast, slower, faster, continueSpeaking, hangUp, openApp(MidasApp) }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .replacingOccurrences(of: "[^a-z0-9ñ ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
    static func words(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init).filter { $0.count > 1 } }

    /// "Jarvis, abre Spotify" → "abre Spotify". The wake word is optional during a call.
    static func stripWakeWord(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = ["^(oye |hola |eh |ey )?(jarvis|yarvis|jarvi|harvis|jarbis)[,.!¿?]*\\s*"]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        // Keep greetings like "Hola, Jarvis" as something the AI should answer.
        if t.isEmpty, normalize(s).hasPrefix("hola") { return "Hola" }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let stopSet = ["espera", "para", "callate", "calla", "silencio", "basta", "stop", "un momento", "callate un momento",
                                  "dejame hablar", "espera un momento", "espera un segundo", "para para", "vale para", "jarvis espera", "jarvis para"]

    static func isStopPhrase(_ s: String) -> Bool {
        let t = normalize(s)
        if stopSet.contains(t) { return true }
        return ["espera", "callate", "dejame hablar", "para un momento", "un momento"].contains { t.hasPrefix($0) } && t.split(separator: " ").count <= 4
    }

    static func parse(_ s: String) -> Command? {
        let t = normalize(s)
        if isStopPhrase(s) { return .stop }
        if ["repite", "repitelo", "repite eso", "que has dicho", "repitemelo", "otra vez lo que has dicho", "como", "perdona que"].contains(t) { return .repeatLast }
        if t.contains("mas despacio") || t.contains("mas lento") { return .slower }
        if t.contains("mas rapido") || t.contains("mas deprisa") { return .faster }
        if ["continua", "sigue", "sigue hablando", "continua por favor", "venga sigue", "sigue por donde ibas"].contains(t) { return .continueSpeaking }
        if ["cuelga", "adios", "hasta luego", "termina la llamada", "corta", "fin de la llamada", "colgamos", "nada mas gracias"].contains(t) { return .hangUp }
        // "abre X" / "ponme X" / "entra en X" / just "Spotify"
        let verbs = ["abre", "abreme", "abrir", "ponme", "pon", "entra en", "entra a", "lanza", "quiero ver", "ve a", "vete a", "inicia", "arranca", "abre la app de", "abre el"]
        for app in MidasApp.all {
            for a in app.aliases {
                if t == a { return .openApp(app) }
                for v in verbs where t == "\(v) \(a)" || t == "\(v) la app de \(a)" || t == "\(v) la aplicacion de \(a)" { return .openApp(app) }
            }
        }
        return nil
    }
}
