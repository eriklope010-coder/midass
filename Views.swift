import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

enum Midas {
    static let obsidian = Color(red: 8/255, green: 8/255, blue: 8/255)
    static let deep = Color(red: 5/255, green: 5/255, blue: 5/255)
    static let charcoal = Color(red: 17/255, green: 17/255, blue: 17/255)
    static let surface = Color(red: 25/255, green: 25/255, blue: 25/255)
    static let gold = Color(red: 198/255, green: 166/255, blue: 106/255)
    static let goldMuted = Color(red: 155/255, green: 129/255, blue: 87/255)
    static let white = Color(red: 241/255, green: 238/255, blue: 232/255)
    static let text2 = Color(red: 150/255, green: 145/255, blue: 138/255)
    static let warn = Color(red: 181/255, green: 101/255, blue: 79/255)
    static func display(_ size: CGFloat) -> Font { .custom("Didot", size: size) }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var call: CallController
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Background()
            if call.inCall { CallView().transition(.opacity) }
            else { HomeView(showSettings: $showSettings).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.6), value: call.inCall)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            Midas.deep
            RadialGradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.045), Midas.obsidian, Midas.deep],
                           center: UnitPoint(x: 0.5, y: 0.36), startRadius: 10, endRadius: 520)
        }.ignoresSafeArea()
    }
}

// MARK: - Golden Core (photoreal still; light responds to real state and real audio level)

struct OrbView: View {
    var state: CallController.State
    @ObservedObject var levels: LevelMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let (rim, core) = lights(t)
            ZStack {
                Image("GoldenCore").resizable().scaledToFit()
                    .saturation(state.isError ? 0.55 : 1)
                    .brightness(state.isError ? -0.12 : 0)
                // rim light
                Circle()
                    .fill(RadialGradient(colors: [.clear, Midas.gold.opacity(0.45), .clear], center: .center, startRadius: 70, endRadius: 150))
                    .blendMode(.screen).opacity(rim).scaleEffect(0.82)
                // inner core
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.88, blue: 0.67).opacity(0.6), Midas.gold.opacity(0.15), .clear], center: .center, startRadius: 0, endRadius: 70))
                    .blendMode(.screen).opacity(core).scaleEffect(0.6)
            }
            .animation(.easeInOut(duration: 0.8), value: state)
        }
        .accessibilityHidden(true)
    }

    private func lights(_ t: Double) -> (Double, Double) {
        let wave = reduceMotion ? 0.5 : (sin(t * .pi * 0.9) * 0.5 + 0.5)
        let out = Double(levels.output), inp = Double(levels.input)
        switch state {
        case .speaking: return (0.25 + out * 0.6, 0.2 + out * 0.9)          // follows Jarvis' real voice
        case .userSpeaking: return (0.35 + inp * 0.6, 0.15)                  // follows the user's voice
        case .listening: return (0.3 + wave * 0.15, 0.12)
        case .thinking: return (0.2, 0.3 + wave * 0.35)
        case .executing: return (0.35 + wave * 0.3, 0.35)
        case .starting: return (0.15 + wave * 0.2, 0.1)
        case .paused, .error: return (0, 0)
        case .idle: return (0.05 + wave * 0.08, 0.05)
        }
    }
}

extension CallController.State {
    var isError: Bool { if case .error = self { return true }; if case .paused = self { return true }; return false }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var call: CallController
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 8) {
                    Text("MIDAS").font(Midas.display(17)).tracking(10).foregroundStyle(Midas.gold)
                    HStack(spacing: 8) {
                        LinearGradient(colors: [.clear, Midas.gold.opacity(0.4)], startPoint: .leading, endPoint: .trailing).frame(width: 70, height: 1)
                        Rectangle().fill(Midas.gold).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                        LinearGradient(colors: [Midas.gold.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 70, height: 1)
                    }
                }
                HStack { Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 18, weight: .light)).foregroundStyle(Midas.gold)
                            .frame(width: 44, height: 44).background(Circle().fill(Midas.charcoal)).overlay(Circle().stroke(Midas.gold.opacity(0.4)))
                    }.accessibilityLabel("Ajustes y memoria")
                }
            }.padding(.top, 8)

            Button { Task { await call.startCall() } } label: {
                OrbView(state: .idle, levels: call.levels).padding(.horizontal, 4)
            }.buttonStyle(.plain).frame(maxHeight: .infinity).accessibilityLabel("Llamar a Jarvis")

            VStack(spacing: 6) {
                Text("JARVIS").font(Midas.display(34)).tracking(14)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.91, green: 0.84, blue: 0.68), Midas.gold, Midas.goldMuted], startPoint: .top, endPoint: .bottom))
                Text(statusLine).font(.system(size: 17, weight: .light)).foregroundStyle(Midas.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button { Task { await call.startCall() } } label: {
                    Label("Llamar", systemImage: "waveform").font(.system(size: 14, weight: .regular)).tracking(2)
                        .padding(.horizontal, 18).padding(.vertical, 9).foregroundStyle(Midas.gold)
                        .overlay(Capsule().stroke(Midas.gold.opacity(0.45)))
                }.padding(.top, 6)
            }

            Image("Pedestal").resizable().scaledToFit().frame(maxHeight: 100).padding(.horizontal, -24).accessibilityHidden(true)

            HStack(spacing: 10) {
                ForEach(MidasApp.all) { app in AppCard(app: app) }
            }

            HStack(spacing: 12) {
                Rectangle().fill(Midas.gold.opacity(0.3)).frame(height: 1)
                Text("MIDAS · PERSONAL AI ASSISTANT").font(.system(size: 10)).tracking(3).foregroundStyle(Midas.goldMuted).fixedSize()
                Rectangle().fill(Midas.gold.opacity(0.3)).frame(height: 1)
            }.padding(.top, 14).padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
    }

    private var statusLine: String {
        if case .error(let m) = call.state { return m }
        return "¿En qué puedo ayudarte?"
    }
}

struct AppCard: View {
    let app: MidasApp
    @State private var note: String?
    var body: some View {
        Button {
            Task { let r = await AppLauncher.open(app); if r == .failed { note = "No se pudo abrir" } }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: app.symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Midas.gold)
                Text(app.name).font(.system(size: 11)).foregroundStyle(Midas.white).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).aspectRatio(1/1.12, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Color(red: 0.11, green: 0.1, blue: 0.08), Midas.deep], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Midas.gold.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 10, y: 8)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Abrir \(app.name)")
        .overlay(alignment: .top) { if let note { Text(note).font(.caption2).foregroundStyle(Midas.warn).offset(y: -16).task { try? await Task.sleep(for: .seconds(2)); self.note = nil } } }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1).animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Call

struct CallView: View {
    @EnvironmentObject var call: CallController
    @AppStorage(Settings.transcriptKey) private var showTranscript = true
    @AppStorage(Settings.modeKey) private var mode = "normal"

    var body: some View {
        let car = mode == "coche"
        VStack(spacing: 12) {
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(call.callStart))
                    Text(String(format: "%02d:%02d", s / 60, s % 60)).monospacedDigit()
                }.font(.system(size: 13)).foregroundStyle(Midas.text2)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(call.micLive ? Color(red: 0.85, green: 0.7, blue: 0.45) : Midas.text2.opacity(0.5)).frame(width: 7, height: 7)
                    Text(call.micLive ? (call.translateFrom != nil ? "Intérprete · \(call.translateFrom!)" : "Micrófono activo") : "Micrófono inactivo")
                }.font(.system(size: 12)).foregroundStyle(Midas.text2)
                    .accessibilityElement(children: .combine)
            }.padding(.horizontal, 20).padding(.top, 8)

            Button { call.tapOrb() } label: { OrbView(state: call.state, levels: call.levels) }
                .buttonStyle(.plain).frame(maxHeight: .infinity).accessibilityLabel("Interrumpir a Jarvis")

            Text(label).font(Midas.display(car ? 26 : 16)).tracking(car ? 6 : 8).foregroundStyle(Midas.gold)
                .accessibilityLabel(label)

            if case .paused(let why) = call.state {
                VStack(spacing: 8) {
                    Text(why).font(.footnote).foregroundStyle(Midas.text2).multilineTextAlignment(.center)
                    Button("Reanudar") { call.retryAudio() }.foregroundStyle(Midas.gold)
                }
            }

            if showTranscript && !car {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(call.lines.suffix(30)) { l in
                                TranscriptLine(line: l).id(l.id)
                            }
                            if !call.partial.isEmpty { Text(call.partial).foregroundStyle(Midas.text2.opacity(0.8)).italic() }
                            if !call.lastSources.isEmpty {
                                ForEach(call.lastSources, id: \.self) { s in
                                    if let u = URL(string: s.url) { Link(s.title, destination: u).font(.caption).foregroundStyle(Midas.goldMuted).lineLimit(1) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    }
                    .frame(maxHeight: 170)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                    .onChange(of: call.lines.count) { _, _ in if let last = call.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                }
            }

            Button { call.endCall() } label: {
                Text("FINALIZAR").font(.system(size: car ? 17 : 13, weight: .medium)).tracking(3)
                    .frame(width: car ? 240 : 170, height: car ? 72 : 54)
                    .background(Capsule().fill(LinearGradient(colors: [Color(red: 0.23, green: 0.11, blue: 0.09), Color(red: 0.13, green: 0.06, blue: 0.05)], startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().stroke(Midas.warn.opacity(0.6)))
                    .foregroundStyle(Color(red: 0.95, green: 0.85, blue: 0.82))
            }.padding(.bottom, 10).accessibilityLabel("Finalizar llamada")
        }
    }

    private var label: String {
        switch call.state {
        case .listening, .userSpeaking: return call.micLive ? call.state.label : "MICRÓFONO INACTIVO"
        case .error: return "ERROR"
        default: return call.state.label
        }
    }
}

struct TranscriptLine: View {
    let line: CallController.Line
    var body: some View {
        switch line.who {
        case .user: (Text("TÚ  ").font(.caption2).foregroundColor(Midas.goldMuted) + Text(line.text).foregroundColor(Midas.text2)).font(.system(size: 15))
        case .jarvis: (Text("JARVIS  ").font(.caption2).foregroundColor(Midas.gold) + Text(line.text).foregroundColor(Midas.white)).font(.system(size: 15))
        case .system: Text(line.text).font(.system(size: 13)).foregroundStyle(Midas.goldMuted)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var memory: MemoryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.serverURLKey) private var server = ""
    @AppStorage(Settings.nameKey) private var name = ""
    @AppStorage(Settings.modeKey) private var mode = "normal"
    @AppStorage(Settings.voiceKey) private var voiceId = ""
    @AppStorage(Settings.rateKey) private var rate = 1.0
    @AppStorage(Settings.keepAwakeKey) private var keepAwake = true
    @AppStorage(Settings.transcriptKey) private var transcript = true
    @AppStorage(Settings.memoryEnabledKey) private var memoryOn = true
    @State private var token = Keychain.read(Settings.tokenKey) ?? ""
    @State private var health: String?
    @State private var editing: MemoryItem?
    @State private var confirmWipe = false
    @State private var exportFile: ExportDoc?
    private let synth = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://tu-servidor.com", text: $server).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    SecureField("Token del dispositivo", text: $token).onChange(of: token) { _, v in Keychain.save(v, for: Settings.tokenKey) }
                    Button("Comprobar conexión") { Task { await check() } }
                    if let health { Text(health).font(.footnote).foregroundStyle(Midas.text2) }
                } header: { Text("Servidor") } footer: { Text("La clave de la IA vive en tu servidor, nunca en el iPhone. El token se guarda en el Llavero.") }

                Section("Tú") {
                    TextField("Cómo quieres que te llame", text: $name)
                    Picker("Modo", selection: $mode) { Text("Normal").tag("normal"); Text("Coche").tag("coche"); Text("Trabajo").tag("trabajo") }
                }

                Section {
                    Picker("Voz de Jarvis", selection: $voiceId) {
                        Text("Automática").tag("")
                        ForEach(SpeechOutput.spanishVoices(), id: \.identifier) { v in
                            Text("\(v.name) · \(v.language)\(v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Mejorada" : "")").tag(v.identifier)
                        }
                    }
                    HStack { Text("Velocidad"); Slider(value: $rate, in: 0.75...1.3) }
                    Button("Probar voz") {
                        let u = AVSpeechUtterance(string: "Aquí estoy. Esta es mi voz.")
                        u.voice = voiceId.isEmpty ? SpeechOutput.spanishVoices().first : AVSpeechSynthesisVoice(identifier: voiceId)
                        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02 * Float(rate); u.pitchMultiplier = 0.94
                        synth.speak(u)
                    }
                    Toggle("Pantalla encendida durante la llamada", isOn: $keepAwake)
                    Toggle("Mostrar transcripción", isOn: $transcript)
                } header: { Text("Voz") } footer: { Text("Para una voz más natural: Ajustes del iPhone › Accesibilidad › Contenido leído › Voces › Español (España), y descarga una voz Mejorada o Premium.") }

                Section {
                    Toggle("Permitir que Jarvis recuerde", isOn: $memoryOn)
                    ForEach(memory.items) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.text)
                            Text("\(m.kind) · \(m.updated.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Midas.text2)
                        }.contentShape(Rectangle()).onTapGesture { editing = m }
                    }.onDelete { idx in idx.map { memory.items[$0].id }.forEach { memory.delete(id: $0) } }
                    if !memory.items.isEmpty {
                        Button("Exportar memoria") { exportFile = ExportDoc(data: memory.exportJSON()) }
                        Button(confirmWipe ? "Pulsa otra vez para borrar todo" : "Borrar toda la memoria", role: .destructive) {
                            if confirmWipe { memory.deleteAll(); confirmWipe = false } else { confirmWipe = true }
                        }
                    }
                } header: { Text("Memoria · \(memory.items.count)") } footer: { Text("Se guarda solo en este iPhone, cifrada por el sistema. Cada llamada envía los recuerdos a tu servidor para que la IA los use.") }

                Section("Siri y atajos") {
                    Text("Di «Oye Siri, llama a Jarvis» para abrir una llamada. También puedes asignarlo al botón de Acción desde Atajos.").font(.footnote)
                }
            }
            .scrollContentBackground(.hidden).background(Midas.obsidian)
            .navigationTitle("MIDAS").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Listo") { dismiss() } }
            .sheet(item: $editing) { m in MemoryEditor(item: m) { memory.update($0) } }
            .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                          document: exportFile, contentType: .json, defaultFilename: "midas-memoria") { _ in exportFile = nil }
        }
        .tint(Midas.gold)
    }

    private func check() async {
        guard let url = URL(string: server)?.appendingPathComponent("health") else { health = "URL no válida."; return }
        do {
            let (d, r) = try await URLSession.shared.data(from: url)
            let ok = (r as? HTTPURLResponse)?.statusCode == 200
            let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            health = ok ? "Conectado · modelo \(obj?["model"] as? String ?? "?")\((obj?["keyConfigured"] as? Bool) == false ? " · ¡falta la clave en el servidor!" : "")" : "El servidor respondió con error."
        } catch { health = "Sin conexión: \(error.localizedDescription)" }
    }
}

struct MemoryEditor: View {
    @State var item: MemoryItem
    var onSave: (MemoryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Recuerdo", text: $item.text, axis: .vertical)
                Picker("Tipo", selection: $item.kind) { ForEach(["preferencia", "dato", "proyecto", "episodio"], id: \.self) { Text($0).tag($0) } }
            }
            .toolbar { Button("Guardar") { onSave(item); dismiss() } }
        }
    }
}

struct ExportDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
