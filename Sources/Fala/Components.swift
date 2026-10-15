import SwiftUI
import AppKit

// MARK: - Live state models

@Observable
final class AccountModel {
    var profile: CodexAuth.Profile? = CodexAuth.profile()
    var codexInstalled = true
    var loggingIn = false
    @ObservationIgnored private var timer: Timer?

    var connected: Bool { profile != nil }

    var label: String {
        guard let profile else { return "Não conectado" }
        let plan = profile.plan.map { " · " + Self.planName($0) } ?? ""
        return (profile.email ?? "Conectado") + plan
    }

    static func planName(_ raw: String) -> String {
        let names = ["plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "team": "Team", "business": "Business",
                     "enterprise": "Enterprise", "edu": "Edu", "go": "Go", "free": "Free"]
        return names[raw] ?? raw.capitalized
    }

    func refresh() {
        profile = CodexAuth.profile()
        DispatchQueue.global().async {
            let installed = CodexCLI.path() != nil
            DispatchQueue.main.async { self.codexInstalled = installed }
        }
    }

    func login() {
        loggingIn = true
        let started = CodexCLI.login { [weak self] _ in
            self?.loggingIn = false
            self?.refresh()
        }
        if !started {
            loggingIn = false
            codexInstalled = false
            return
        }
        // Also poll, in case the process outlives the browser flow.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.profile = CodexAuth.profile()
            if self.profile != nil { self.loggingIn = false; t.invalidate() }
        }
    }
}

@Observable
final class AppleModelModel {
    var state: AppleTranscriber.ModelState = .missing
    var error: String?

    func refresh(language: String) {
        Task { @MainActor in
            let s = await AppleTranscriber.modelState(language: language)
            if case .downloading = self.state, s != .ready { return }
            self.state = s
        }
    }

    func install(language: String) {
        error = nil
        state = .downloading(0)
        Task { @MainActor in
            do {
                try await AppleTranscriber.installModel(language: language) { p in
                    DispatchQueue.main.async { self.state = p >= 1 ? .ready : .downloading(p) }
                }
                self.state = .ready
            } catch {
                self.error = error.localizedDescription
                self.state = await AppleTranscriber.modelState(language: language)
            }
        }
    }
}

@Observable
final class PermissionModel {
    var microphone = Permissions.microphone == .authorized
    var accessibility = Permissions.accessibility
    @ObservationIgnored private var timer: Timer?

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stopPolling() { timer?.invalidate() }

    func poll() {
        microphone = Permissions.microphone == .authorized
        accessibility = Permissions.accessibility
    }

    func requestMicrophone() {
        if Permissions.microphone == .notDetermined {
            Task { @MainActor in
                _ = await Permissions.requestMicrophone()
                poll()
            }
        } else {
            Permissions.openSettings("Privacy_Microphone")
        }
    }
}

// MARK: - Shortcut recorder

struct KeyCap: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(.system(size: large ? 17 : 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, large ? 12 : 8)
            .frame(minWidth: large ? 40 : 26, minHeight: large ? 40 : 26)
            .background {
                RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1))
            }
    }
}

struct ShortcutRecorder: View {
    @Bindable var settings = AppSettings.shared
    var large = false

    @State private var recording = false
    @State private var monitor: Any?
    @State private var held: CGEventFlags = []
    @State private var lastModifier: UInt16?

    var body: some View {
        Button {
            recording ? stop() : begin()
        } label: {
            HStack(spacing: 6) {
                if recording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(held.isEmpty ? "Pressione o atalho…" : Shortcut(keyCode: lastModifier ?? 0, modifiers: 0).partsForFlags(held).joined(separator: " "))
                        .font(.system(size: large ? 15 : 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(settings.shortcut.parts.enumerated()), id: \.offset) { _, part in
                        KeyCap(text: part, large: large)
                    }
                }
            }
            .padding(.horizontal, large ? 16 : 8)
            .padding(.vertical, large ? 10 : 4)
            .frame(minWidth: large ? 240 : 140, minHeight: large ? 60 : 34)
            .contentShape(.capsule)
            .glassEffect(recording ? .regular.tint(.red.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Clique e pressione uma tecla, combinação, ou um modificador sozinho (ex: ⌥ direito, fn)")
        .onDisappear { stop() }
    }

    private func begin() {
        HotkeyMonitor.shared.paused = true
        held = []
        lastModifier = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotkeyMonitor.shared.paused = false
    }

    private func commit(_ s: Shortcut) {
        settings.shortcut = s
        HotkeyMonitor.shared.shortcut = s
        stop()
    }

    private func handle(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(Shortcut.relevant)
        if event.type == .keyDown {
            if event.keyCode == 53, flags.isEmpty { stop(); return } // esc cancels
            var f = flags
            if Self.navigationKeys.contains(event.keyCode) { f.remove(.maskSecondaryFn) }
            commit(Shortcut(keyCode: event.keyCode, modifiers: f.rawValue))
        } else if event.type == .flagsChanged, let own = Shortcut.modifierKeys[event.keyCode] {
            if flags.contains(own) {
                held.formUnion(flags)
                lastModifier = event.keyCode
            } else if flags.isEmpty, let last = lastModifier {
                let others = held.subtracting(Shortcut.modifierKeys[last]!)
                commit(Shortcut(keyCode: last, modifiers: others.rawValue))
            }
        }
    }

    /// Keys macOS reports with the fn flag set even when fn is not physically held.
    private static let navigationKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        123, 124, 125, 126, 115, 119, 116, 121, 117,
    ]
}

private extension Shortcut {
    func partsForFlags(_ f: CGEventFlags) -> [String] {
        var out: [String] = []
        if f.contains(.maskSecondaryFn) { out.append("fn") }
        if f.contains(.maskControl) { out.append("⌃") }
        if f.contains(.maskAlternate) { out.append("⌥") }
        if f.contains(.maskShift) { out.append("⇧") }
        if f.contains(.maskCommand) { out.append("⌘") }
        return out
    }
}

// MARK: - Rows

struct StatusRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct GrantedBadge: View {
    var body: some View {
        Label("Pronto", systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.green)
            .transition(.scale.combined(with: .opacity))
    }
}

struct AccountRow: View {
    let account: AccountModel

    var body: some View {
        StatusRow(symbol: "sparkles", title: "Conta ChatGPT", detail: account.connected ? account.label : (account.codexInstalled ? "Usa o mesmo login do Codex — sem chave de API" : "Instale o Codex CLI: npm i -g @openai/codex"),
                  tint: account.connected ? .green : .accentColor) {
            if account.connected {
                GrantedBadge()
            } else if account.loggingIn {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Aguardando navegador…").font(.caption).foregroundStyle(.secondary) }
            } else if account.codexInstalled {
                Button("Entrar com ChatGPT") { account.login() }.buttonStyle(.glassProminent)
            } else {
                Button("Copiar comando") { Paster.copy("npm i -g @openai/codex") }.buttonStyle(.glass)
            }
        }
        .animation(.spring, value: account.connected)
    }
}

struct AppleModelRow: View {
    let model: AppleModelModel
    let language: String

    var body: some View {
        StatusRow(symbol: "apple.logo", title: "Modelo on-device", detail: detail, tint: model.state == .ready ? .green : .accentColor) {
            switch model.state {
            case .ready: GrantedBadge()
            case .unsupported: Text("Indisponível").font(.caption).foregroundStyle(.secondary)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 90)
            case .missing:
                Button("Baixar modelo") { model.install(language: language) }.buttonStyle(.glassProminent)
            }
        }
        .onAppear { model.refresh(language: language) }
        .onChange(of: language) { _, new in model.refresh(language: new) }
    }

    private var detail: String {
        if let e = model.error { return e }
        switch model.state {
        case .ready: return "Instalado. Funciona offline."
        case .unsupported: return "Este idioma não é suportado pelo modelo da Apple"
        case .downloading: return "Baixando modelo de fala da Apple…"
        case .missing: return "Download único feito pelo macOS"
        }
    }
}

struct PermissionRows: View {
    let permissions: PermissionModel

    var body: some View {
        VStack(spacing: 16) {
            StatusRow(symbol: "mic.fill", title: "Microfone", detail: "Para ouvir você enquanto o atalho está ativo", tint: permissions.microphone ? .green : .accentColor) {
                if permissions.microphone { GrantedBadge() } else {
                    Button("Permitir") { permissions.requestMicrophone() }.buttonStyle(.glassProminent)
                }
            }
            StatusRow(symbol: "accessibility", title: "Acessibilidade", detail: "Para detectar o atalho em qualquer app e digitar o texto", tint: permissions.accessibility ? .green : .accentColor) {
                if permissions.accessibility { GrantedBadge() } else {
                    Button("Abrir Ajustes") { Permissions.promptAccessibility() }.buttonStyle(.glassProminent)
                }
            }
        }
        .animation(.spring, value: permissions.microphone)
        .animation(.spring, value: permissions.accessibility)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

/// The app glyph: a glass orb with a living waveform.
struct AppGlyph: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.93, green: 0.36, blue: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Waveform(level: 0.6, color: .white, thinking: false, bars: 7, maxHeight: size * 0.42, barWidth: size * 0.045)
        }
        .frame(width: size, height: size)
        .glassEffect(.regular.tint(.white.opacity(0.05)), in: .circle)
        .shadow(color: Color(red: 0.6, green: 0.3, blue: 1).opacity(0.45), radius: size * 0.3, y: size * 0.1)
    }
}
