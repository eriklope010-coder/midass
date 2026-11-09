import Foundation

/// Streams a turn from the MIDAS backend. The Anthropic key never reaches the phone:
/// the app only holds the backend URL and a device token (stored in the Keychain).
struct JarvisAPI {
    struct Message: Codable { let role: String; let content: String }
    struct MemoryDTO: Codable { let id: String; let kind: String; let text: String }
    struct TurnRequest: Encodable {
        let messages: [Message]
        let memories: [MemoryDTO]
        let mode: String
        let translateFrom: String?
        let now: String
        let timezone: String
        let name: String
    }
    struct Action { let id: String; let name: String; let input: [String: Any] }
    struct Source: Hashable { let title: String; let url: String }

    enum Event {
        case text(String)
        case action(Action)
        case searching(String)
        case sources([Source])
        case done
        case failure(String)
    }

    enum APIError: LocalizedError {
        case notConfigured, unauthorized, http(Int), offline
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Falta configurar el servidor de MIDAS en Ajustes."
            case .unauthorized: return "El servidor rechazó el token del dispositivo."
            case .http(let c): return "El servidor respondió con un error (\(c))."
            case .offline: return "No hay conexión con el servidor."
            }
        }
    }

    let baseURL: URL
    let token: String

    static func fromSettings() -> JarvisAPI? {
        guard let s = UserDefaults.standard.string(forKey: Settings.serverURLKey),
              let url = URL(string: s.trimmingCharacters(in: .whitespaces)), url.scheme == "https" || url.host == "localhost",
              let token = Keychain.read(Settings.tokenKey), !token.isEmpty else { return nil }
        return JarvisAPI(baseURL: url, token: token)
    }

    func stream(_ req: TurnRequest) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var r = URLRequest(url: baseURL.appendingPathComponent("turn"))
                    r.httpMethod = "POST"
                    r.timeoutInterval = 60
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    r.httpBody = try JSONEncoder().encode(req)

                    let (bytes, response) = try await URLSession.shared.bytes(for: r)
                    guard let http = response as? HTTPURLResponse else { throw APIError.offline }
                    if http.statusCode == 401 { throw APIError.unauthorized }
                    guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }

                    var event = ""
                    // AsyncLineSequence skips blank lines, so pair each data: line with the last event: line.
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
                        switch event {
                        case "text":
                            if let d = obj["delta"] as? String { continuation.yield(.text(d)) }
                        case "action":
                            continuation.yield(.action(Action(id: obj["id"] as? String ?? UUID().uuidString,
                                                              name: obj["name"] as? String ?? "",
                                                              input: obj["input"] as? [String: Any] ?? [:])))
                        case "search":
                            continuation.yield(.searching(obj["query"] as? String ?? ""))
                        case "sources":
                            let items = (obj["items"] as? [[String: Any]] ?? []).compactMap { d -> Source? in
                                guard let u = d["url"] as? String else { return nil }
                                return Source(title: d["title"] as? String ?? u, url: u)
                            }
                            continuation.yield(.sources(items))
                        case "error":
                            continuation.yield(.failure(obj["message"] as? String ?? "Error del servidor."))
                        case "done":
                            continuation.yield(.done)
                        default: break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as URLError where e.code == .cancelled {
                    continuation.finish()
                } catch let e as URLError {
                    continuation.finish(throwing: e.code == .notConnectedToInternet || e.code == .cannotFindHost ? APIError.offline : e)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
