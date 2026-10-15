import SwiftUI
import Observation

enum Phase: Equatable {
    case idle, listening, transcribing, done, error(String)
}

@Observable
final class DictationController {
    static let shared = DictationController()

    var phase: Phase = .idle
    /// Smoothed microphone level 0...1 for the waveform.
    var level: Float = 0
    /// Live text (Apple engine only).
    var partial = ""
    var startedAt: Date?
    var latched = false

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var apple: AppleTranscriber?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored private var session = 0

    private init() {
        recorder.onLevel = { [weak self] value in
            DispatchQueue.main.async {
                guard let self else { return }
                // Fast attack, slower release feels natural.
                self.level = value > self.level ? value * 0.7 + self.level * 0.3 : value * 0.25 + self.level * 0.75
            }
        }
    }

    // MARK: Hotkey

    func hotkeyPressed() {
        switch phase {
        case .listening:
            if latched { finish() }
        case .transcribing:
            break
        default:
            start()
        }
    }

    func hotkeyReleased() {
        guard phase == .listening, let startedAt else { return }
        let held = Date().timeIntervalSince(startedAt)
        switch settings.mode {
        case .hold:
            held < 0.25 ? cancel(silently: true) : finish()
        case .toggle:
            latched = true
        case .hybrid:
            if held < 0.35 { latched = true } else { finish() }
        }
    }

    /// Another key was typed while a modifier-only shortcut was held: user is typing, not dictating.
    func hotkeyInterrupted() {
        guard phase == .listening, !latched, let startedAt, Date().timeIntervalSince(startedAt) < 1.0 else { return }
        cancel(silently: true)
    }

    func escape() -> Bool {
        switch phase {
        case .listening, .transcribing:
            cancel(silently: false)
            return true
        default:
            return false
        }
    }

    // MARK: Flow

    func start() {
        guard Permissions.microphone == .authorized else {
            if Permissions.microphone == .notDetermined {
                Task { _ = await Permissions.requestMicrophone() }
            } else {
                show(error: "Permita o acesso ao microfone")
            }
            return
        }
        hideWork?.cancel()
        job?.cancel()
        session += 1
        partial = ""
        level = 0
        latched = false

        if settings.engine == .apple {
            let apple = AppleTranscriber()
            let id = session
            apple.onPartial = { [weak self] text in
                DispatchQueue.main.async { if self?.session == id { self?.partial = text } }
            }
            recorder.onBuffer = { [weak apple] buffer in apple?.append(buffer) }
            apple.start(language: settings.language)
            self.apple = apple
        } else {
            recorder.onBuffer = nil
            apple = nil
        }

        do {
            try recorder.start()
        } catch {
            show(error: error.localizedDescription)
            return
        }
        startedAt = .now
        Sound.play("Tink")
        withAnimation { phase = .listening }
    }

    func finish() {
        guard phase == .listening else { return }
        let (wav, seconds) = recorder.stop()
        let peak = recorder.peak
        Sound.play("Pop")
        phase = .transcribing
        let engine = settings.engine
        let language = settings.language
        let apple = self.apple
        let id = session

        if peak < 0.06 || seconds < 0.3 {
            apple?.cancel()
            show(error: "Não ouvi nada")
            return
        }

        job = Task { @MainActor in
            do {
                let text: String
                switch engine {
                case .chatgpt: text = try await ChatGPTTranscriber.transcribe(wav: wav, language: language)
                case .apple: text = try await apple?.finish() ?? ""
                }
                guard id == session, !Task.isCancelled else { return }
                if text.isEmpty {
                    show(error: "Não ouvi nada")
                    return
                }
                settings.remember(text)
                Paster.insert(text, restoreClipboard: settings.restoreClipboard)
                phase = .done
                scheduleHide(after: 0.9)
            } catch {
                guard id == session, !Task.isCancelled else { return }
                show(error: error.localizedDescription)
            }
        }
    }

    func cancel(silently: Bool) {
        session += 1
        job?.cancel()
        if phase == .listening { recorder.stop() }
        apple?.cancel()
        apple = nil
        latched = false
        if silently {
            phase = .idle
        } else {
            Sound.play("Funk")
            phase = .error("Cancelado")
            scheduleHide(after: 0.8)
        }
    }

    private func show(error message: String) {
        phase = .error(message)
        scheduleHide(after: 2.4)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .listening = self.phase { return }
            if case .transcribing = self.phase { return }
            self.phase = .idle
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Demo (fala --demo): plays the overlay states without touching the microphone.

    func demo(partialText: Bool) {
        startedAt = .now
        phase = .listening
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { timer in
            t += 1 / 30
            self.level = Float(0.35 + 0.35 * sin(t * 7) * sin(t * 2.3) + 0.2)
            if partialText { self.partial = String("Isso é uma demonstração do Fala transcrevendo ao vivo".prefix(Int(t * 18))) }
            if t > 3.2 {
                timer.invalidate()
                self.phase = .transcribing
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    self.partial = ""
                    self.phase = .done
                    self.scheduleHide(after: 1.2)
                }
            }
        }
    }
}
