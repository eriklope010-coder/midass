import SwiftUI
import AppIntents

@main
struct JarvisMidasApp: App {
    @StateObject private var memory: MemoryStore
    @StateObject private var call: CallController
    @StateObject private var launcher = CallLauncher.shared
    @Environment(\.scenePhase) private var phase

    init() {
        let m = MemoryStore()
        _memory = StateObject(wrappedValue: m)
        _call = StateObject(wrappedValue: CallController(memory: m))
        JarvisShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(memory)
                .environmentObject(call)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // jarvismidas://call — for Shortcuts, the Action Button or a widget.
                    if url.host == "call" { launcher.pendingStart = true }
                }
                .onChange(of: launcher.pendingStart) { _, start in
                    if start { launcher.pendingStart = false; Task { await call.startCall() } }
                }
                .onChange(of: phase) { _, p in
                    if p == .active, launcher.pendingStart { launcher.pendingStart = false; Task { await call.startCall() } }
                }
        }
    }
}

/// Bridges Siri / Shortcuts into the running app.
@MainActor
final class CallLauncher: ObservableObject {
    static let shared = CallLauncher()
    @Published var pendingStart = false
}

// MARK: - Siri & Shortcuts (App Intents)

struct StartJarvisCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Llamar a Jarvis"
    static var description = IntentDescription("Abre MIDAS y empieza una llamada de voz continua con Jarvis.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CallLauncher.shared.pendingStart = true
        return .result()
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartJarvisCallIntent(),
            phrases: [
                "Llama a \(.applicationName)",
                "Habla con \(.applicationName)",
                "Hola \(.applicationName)",
                "Abre \(.applicationName) en modo llamada",
            ],
            shortTitle: "Llamar a Jarvis",
            systemImageName: "waveform.circle"
        )
    }
}
