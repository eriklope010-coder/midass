import UIKit
import EventKit

// MARK: - App launching

struct MidasApp: Identifiable, Hashable {
    let id: String
    let name: String
    let scheme: String      // must also be listed in LSApplicationQueriesSchemes
    let web: String
    let symbol: String      // SF Symbol shown on the card
    let aliases: [String]

    static let all: [MidasApp] = [
        .init(id: "whatsapp", name: "WhatsApp", scheme: "whatsapp://", web: "https://wa.me/", symbol: "message.fill",
              aliases: ["whatsapp", "wasap", "guasap", "wassap", "whats", "wsp", "wasa"]),
        .init(id: "spotify", name: "Spotify", scheme: "spotify://", web: "https://open.spotify.com/", symbol: "waveform",
              aliases: ["spotify", "spoty", "spoti", "espotifai", "espoti", "spotifai"]),
        .init(id: "instagram", name: "Instagram", scheme: "instagram://app", web: "https://www.instagram.com/", symbol: "camera.fill",
              aliases: ["instagram", "insta", "instagran", "ig"]),
        .init(id: "tiktok", name: "TikTok", scheme: "snssdk1233://", web: "https://www.tiktok.com/", symbol: "music.note",
              aliases: ["tiktok", "tik tok", "tictoc", "tic toc", "tictok", "titok"]),
        .init(id: "plex", name: "Plex", scheme: "plex://", web: "https://app.plex.tv/", symbol: "play.rectangle.fill",
              aliases: ["plex", "pleks", "plexs"]),
    ]
    static func find(_ id: String) -> MidasApp? { all.first { $0.id == id } }
}

enum LaunchOutcome { case openedApp, openedWeb, failed }

@MainActor
enum AppLauncher {
    /// Opens the installed app; if it is not installed, opens its website. Reports what really happened.
    static func open(_ app: MidasApp) async -> LaunchOutcome {
        if let url = URL(string: app.scheme), UIApplication.shared.canOpenURL(url) {
            return await UIApplication.shared.open(url) ? .openedApp : .failed
        }
        if let web = URL(string: app.web), await UIApplication.shared.open(web) { return .openedWeb }
        return .failed
    }

    /// Opens Spotify on a search. Starting playback from another app needs the Spotify iOS SDK.
    static func spotifySearch(_ query: String) async -> LaunchOutcome {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        if let probe = URL(string: "spotify://"), UIApplication.shared.canOpenURL(probe),
           let url = URL(string: "spotify:search:\(q)") {
            return await UIApplication.shared.open(url) ? .openedApp : .failed
        }
        if let web = URL(string: "https://open.spotify.com/search/\(q)"), await UIApplication.shared.open(web) { return .openedWeb }
        return .failed
    }
}

// MARK: - Reminders (EventKit, real reminders in the iOS Reminders app)

enum ReminderOutcome { case created(Date?), denied, failed(String) }

@MainActor
enum RemindersService {
    private static let store = EKEventStore()

    static func add(title: String, dueISO: String?) async -> ReminderOutcome {
        do {
            let granted: Bool
            if #available(iOS 17.0, *) { granted = try await store.requestFullAccessToReminders() }
            else { granted = try await store.requestAccess(to: .reminder) }
            guard granted else { return .denied }
            let r = EKReminder(eventStore: store)
            r.title = title
            guard let cal = store.defaultCalendarForNewReminders() else { return .failed("No hay una lista de recordatorios por defecto.") }
            r.calendar = cal
            var due: Date?
            if let iso = dueISO, let d = parseDate(iso) {
                due = d
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                r.addAlarm(EKAlarm(absoluteDate: d))
            }
            try store.save(r, commit: true)
            return .created(due)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]] {
            f.formatOptions = opts
            f.timeZone = .current
            if let d = f.date(from: s) { return d }
        }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
