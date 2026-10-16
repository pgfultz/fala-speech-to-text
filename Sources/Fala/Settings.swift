import Foundation
import Observation

/// Interface language. English is the default; Portuguese can be picked in onboarding or Settings.
enum UILanguage: String, CaseIterable, Identifiable {
    case en, pt
    var id: String { rawValue }
    var name: String { self == .en ? "English" : "Português" }
}

/// Returns the string for the current interface language. Views re-render on change because
/// this reads an observable setting.
func tr(_ en: String, _ pt: String) -> String {
    AppSettings.shared.uiLanguage == .pt ? pt : en
}

enum Engine: String, CaseIterable, Identifiable {
    case chatgpt, apple
    var id: String { rawValue }
    var title: String { self == .chatgpt ? "ChatGPT" : "Apple on-device" }
    var subtitle: String {
        switch self {
        case .chatgpt: tr("Your ChatGPT subscription, via the Codex login. Highest accuracy.", "Sua assinatura do ChatGPT, via login do Codex. Máxima precisão.")
        case .apple: tr("Runs 100% on your Mac. Offline, private and instant.", "Roda 100% no seu Mac. Offline, privado e instantâneo.")
        }
    }
    var symbol: String { self == .chatgpt ? "sparkles" : "apple.logo" }
}

enum TriggerMode: String, CaseIterable, Identifiable {
    case hybrid, hold, toggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hybrid: tr("Smart", "Inteligente")
        case .hold: tr("Hold", "Segurar")
        case .toggle: tr("Toggle", "Alternar")
        }
    }
    var detail: String {
        switch self {
        case .hybrid: tr("Hold to talk, release to send. A quick tap locks recording until the next tap.", "Segure para falar e solte para enviar. Um toque rápido trava a gravação até o próximo toque.")
        case .hold: tr("Records only while the shortcut is held.", "Grava apenas enquanto o atalho estiver pressionado.")
        case .toggle: tr("One tap starts, another tap stops.", "Um toque começa, outro toque termina.")
        }
    }
}

enum PillStyle: String, CaseIterable, Identifiable {
    case auto, notch, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: tr("Automatic", "Automático")
        case .notch: "Notch"
        case .floating: tr("Glass pill", "Pílula de vidro")
        }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static var all: [LanguageOption] { [
        .init(code: "auto", name: tr("Detect automatically", "Detectar automaticamente")),
        .init(code: "pt", name: "Português"),
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "it", name: "Italiano"),
        .init(code: "ja", name: "日本語"),
        .init(code: "zh", name: "中文"),
    ] }
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var date: Date
    var engine: String
}

@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let d = UserDefaults.standard

    var uiLanguage: UILanguage { didSet { d.set(uiLanguage.rawValue, forKey: "uiLanguage") } }
    var engine: Engine { didSet { d.set(engine.rawValue, forKey: "engine") } }
    var shortcut: Shortcut { didSet { d.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") } }
    var mode: TriggerMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    var language: String { didSet { d.set(language, forKey: "language") } }
    var pillStyle: PillStyle { didSet { d.set(pillStyle.rawValue, forKey: "pillStyle") } }
    var restoreClipboard: Bool { didSet { d.set(restoreClipboard, forKey: "restoreClipboard") } }
    var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    var history: [HistoryItem] { didSet { d.set(try? JSONEncoder().encode(history), forKey: "history") } }

    private init() {
        uiLanguage = UILanguage(rawValue: d.string(forKey: "uiLanguage") ?? "") ?? .en
        engine = Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .chatgpt
        shortcut = (d.data(forKey: "shortcut")).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        mode = TriggerMode(rawValue: d.string(forKey: "mode") ?? "") ?? .hybrid
        language = d.string(forKey: "language") ?? "auto"
        pillStyle = PillStyle(rawValue: d.string(forKey: "pillStyle") ?? "") ?? .auto
        restoreClipboard = d.object(forKey: "restoreClipboard") as? Bool ?? true
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        onboarded = d.bool(forKey: "onboarded")
        history = (d.data(forKey: "history")).flatMap { try? JSONDecoder().decode([HistoryItem].self, from: $0) } ?? []
    }

    func remember(_ text: String) {
        history.insert(HistoryItem(text: text, date: .now, engine: engine.rawValue), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
    }
}
