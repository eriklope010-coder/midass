import Foundation
import Security

// MARK: - Settings (non-secret) — UserDefaults

enum Settings {
    static let serverURLKey = "midas.serverURL"
    static let tokenKey = "midas.deviceToken"          // Keychain, never UserDefaults
    static let nameKey = "midas.userName"
    static let modeKey = "midas.mode"                  // normal | coche | trabajo
    static let voiceKey = "midas.voiceId"
    static let rateKey = "midas.rate"
    static let keepAwakeKey = "midas.keepAwake"
    static let transcriptKey = "midas.showTranscript"
    static let memoryEnabledKey = "midas.memoryEnabled"
}

// MARK: - Keychain

enum Keychain {
    static func save(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Persistent memory (long-term + episodic), on-device, file-protected

struct MemoryItem: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.prefix(8).lowercased()
    var kind: String           // preferencia | dato | proyecto | episodio
    var text: String
    var created = Date()
    var updated = Date()
}

@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var items: [MemoryItem] = []
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("midas-memory.json")
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([MemoryItem].self, from: d) { items = list }
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: Settings.memoryEnabledKey) as? Bool ?? true }

    @discardableResult
    func add(kind: String, text: String, replacing id: String? = nil) -> Bool {
        guard enabled else { return false }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if let id, let i = items.firstIndex(where: { $0.id == id }) {
            items[i].text = clean; items[i].kind = kind; items[i].updated = Date()
        } else if !items.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) {
            items.insert(MemoryItem(kind: kind, text: clean), at: 0)
        }
        save(); return true
    }

    func update(_ item: MemoryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item; items[i].updated = Date(); save()
    }
    func delete(id: String) { items.removeAll { $0.id == id }; save() }
    func deleteAll() { items.removeAll(); save() }
    func exportJSON() -> Data { (try? JSONEncoder().encode(items)) ?? Data() }

    /// The memories sent with each turn (most recent first, capped).
    func forPrompt() -> [JarvisAPI.MemoryDTO] {
        guard enabled else { return [] }
        return items.sorted { $0.updated > $1.updated }.prefix(60).map { .init(id: $0.id, kind: $0.kind, text: $0.text) }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        // Readable after first unlock so Jarvis can remember during a call with the screen locked.
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
