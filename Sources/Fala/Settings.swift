import Foundation
import Observation

enum Engine: String, CaseIterable, Identifiable {
    case chatgpt, apple
    var id: String { rawValue }
    var title: String { self == .chatgpt ? "ChatGPT" : "Apple on-device" }
    var subtitle: String {
        switch self {
        case .chatgpt: "Sua assinatura do ChatGPT, via login do Codex. Máxima precisão."
        case .apple: "Roda 100% no seu Mac. Offline, privado e instantâneo."
        }
    }
    var symbol: String { self == .chatgpt ? "sparkles" : "apple.logo" }
}

enum TriggerMode: String, CaseIterable, Identifiable {
    case hybrid, hold, toggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hybrid: "Inteligente"
        case .hold: "Segurar"
        case .toggle: "Alternar"
        }
    }
    var detail: String {
        switch self {
        case .hybrid: "Segure para falar e solte para enviar. Um toque rápido trava a gravação até o próximo toque."
        case .hold: "Grava apenas enquanto o atalho estiver pressionado."
        case .toggle: "Um toque começa, outro toque termina."
        }
    }
}

enum PillStyle: String, CaseIterable, Identifiable {
    case auto, notch, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automático"
        case .notch: "Notch"
        case .floating: "Pílula de vidro"
        }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [LanguageOption] = [
        .init(code: "auto", name: "Detectar automaticamente"),
        .init(code: "pt", name: "Português"),
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "it", name: "Italiano"),
        .init(code: "ja", name: "日本語"),
        .init(code: "zh", name: "中文"),
    ]
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
