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
            .font(.system(size: large ? 15 : 12, weight: .medium))
            .padding(.horizontal, large ? 12 : 8)
            .frame(minWidth: large ? 40 : 26, minHeight: large ? 40 : 26)
            .background {
                RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
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
                    Circle()
                        .fill(.primary)
                        .frame(width: 6, height: 6)
                        .phaseAnimator([1.0, 0.3]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.7) }
                    Text(held.isEmpty ? "Pressione o atalho…" : Shortcut(keyCode: lastModifier ?? 0, modifiers: 0).partsForFlags(held).joined(separator: " "))
                        .font(.system(size: large ? 14 : 12.5))
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
            .background(.quaternary.opacity(recording ? 0.8 : 0.45), in: .capsule)
            .overlay(Capsule().strokeBorder(recording ? AnyShapeStyle(.primary.opacity(0.7)) : AnyShapeStyle(.separator.opacity(0.6))))
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
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct GrantedBadge: View {
    var body: some View {
        Label("Pronto", systemImage: "checkmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .transition(.scale.combined(with: .opacity))
    }
}

struct AccountRow: View {
    let account: AccountModel

    var body: some View {
        StatusRow(symbol: "sparkles", title: "Conta ChatGPT", detail: account.connected ? account.label : (account.codexInstalled ? "Usa o mesmo login do Codex — sem chave de API" : "Instale o Codex CLI: npm i -g @openai/codex")) {
            if account.connected {
                GrantedBadge()
            } else if account.loggingIn {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Aguardando navegador…").font(.caption).foregroundStyle(.secondary) }
            } else if account.codexInstalled {
                Button("Entrar com ChatGPT") { account.login() }.buttonStyle(PillButtonStyle(prominent: true))
            } else {
                Button("Copiar comando") { Paster.copy("npm i -g @openai/codex") }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .animation(.spring, value: account.connected)
    }
}

struct AppleModelRow: View {
    let model: AppleModelModel
    let language: String

    var body: some View {
        StatusRow(symbol: "apple.logo", title: "Modelo on-device", detail: detail) {
            switch model.state {
            case .ready: GrantedBadge()
            case .unsupported: Text("Indisponível").font(.caption).foregroundStyle(.secondary)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 90)
            case .missing:
                Button("Baixar modelo") { model.install(language: language) }.buttonStyle(PillButtonStyle(prominent: true))
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
            StatusRow(symbol: "mic.fill", title: "Microfone", detail: "Para ouvir você enquanto o atalho está ativo") {
                if permissions.microphone { GrantedBadge() } else {
                    Button("Permitir") { permissions.requestMicrophone() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            StatusRow(symbol: "accessibility", title: "Acessibilidade", detail: "Para detectar o atalho em qualquer app e digitar o texto") {
                if permissions.accessibility { GrantedBadge() } else {
                    Button("Abrir Ajustes") { Permissions.promptAccessibility() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
        .animation(.spring, value: permissions.microphone)
        .animation(.spring, value: permissions.accessibility)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

/// The app mark, drawn to match the icon: a graphite squircle with a quiet white waveform.
struct AppMark: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            HStack(spacing: size * 0.048) {
                ForEach(Array([0.13, 0.25, 0.39, 0.52, 0.39, 0.25, 0.13].enumerated()), id: \.offset) { _, h in
                    Capsule().fill(.white).frame(width: size * 0.06, height: size * h)
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: size * 0.12, y: size * 0.05)
    }
}

/// Neutral capsule buttons: prominent is solid label-colored (black in light mode, white in dark).
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, prominent ? 18 : 14)
            .frame(height: 30)
            .foregroundStyle(prominent ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.primary))
            .background {
                Capsule().fill(prominent ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.quaternary))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}
