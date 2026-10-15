import AVFoundation
import Speech

/// Streams microphone buffers into Apple's on-device speech models (SpeechAnalyzer, macOS 26).
final class AppleTranscriber {
    var onPartial: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var startError: Error?
    private var finishRequested = false
    private var startTask: Task<Void, Never>?

    static func locale(for code: String) -> Locale {
        if code == "auto" { return Locale.current }
        let map = ["pt": "pt-BR", "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
                   "it": "it-IT", "ja": "ja-JP", "zh": "zh-CN"]
        return Locale(identifier: map[code] ?? code)
    }

    /// SpeechTranscriber is the new, much better macOS 26 model; DictationTranscriber covers devices without it.
    static var useSpeechTranscriber: Bool { SpeechTranscriber.isAvailable }

    static func supportedLocale(_ code: String) async -> Locale? {
        let wanted = locale(for: code)
        return useSpeechTranscriber
            ? await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
            : await DictationTranscriber.supportedLocale(equivalentTo: wanted)
    }

    static func makeModule(_ locale: Locale) -> any SpeechModule {
        if useSpeechTranscriber {
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        }
        return DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                    reportingOptions: [.volatileResults], attributeOptions: [])
    }

    enum ModelState: Equatable { case unsupported, missing, downloading(Double), ready }

    static func modelState(language: String) async -> ModelState {
        guard let locale = await supportedLocale(language) else { return .unsupported }
        switch await AssetInventory.status(forModules: [makeModule(locale)]) {
        case .installed: return .ready
        case .unsupported: return .unsupported
        case .downloading: return .downloading(0)
        default: return .missing
        }
    }

    /// Downloads the on-device model if needed, reporting progress 0...1.
    static func installModel(language: String, progress: @escaping (Double) -> Void) async throws {
        guard let locale = await supportedLocale(language) else { throw AppleError.unsupportedLanguage }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule(locale)]) {
            let observer = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            defer { observer.invalidate() }
            try await request.downloadAndInstall()
        }
        progress(1)
    }

    enum AppleError: LocalizedError {
        case unsupportedLanguage
        var errorDescription: String? { "Idioma não suportado pelo modelo da Apple" }
    }

    /// Starts the analyzer. Audio appended before it is ready is queued, so nothing is lost.
    func start(language: String) {
        finalized = ""
        volatile = ""
        startError = nil
        finishRequested = false
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation

        startTask = Task {
            do {
                guard let locale = await Self.supportedLocale(language) else { throw AppleError.unsupportedLanguage }
                let module = Self.makeModule(locale)
                if await AssetInventory.status(forModules: [module]) != .installed {
                    try await Self.installModel(language: language) { _ in }
                }
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
                let analyzer = SpeechAnalyzer(modules: [module])
                self.analyzer = analyzer
                self.resultsTask = Task { [weak self] in
                    do {
                        if let m = module as? SpeechTranscriber {
                            for try await r in m.results { self?.receive(String(r.text.characters), final: r.isFinal) }
                        } else if let m = module as? DictationTranscriber {
                            for try await r in m.results { self?.receive(String(r.text.characters), final: r.isFinal) }
                        }
                    } catch {}
                }
                lock.withLock {
                    self.format = format
                    for buffer in pending { feed(buffer) }
                    pending.removeAll()
                    if finishRequested { continuation.finish() }
                }
                try await analyzer.start(inputSequence: stream)
            } catch {
                self.startError = error
                continuation.finish()
            }
        }
    }

    private func receive(_ text: String, final: Bool) {
        if final {
            let joiner = finalized.isEmpty || text.first?.isWhitespace == true ? "" : " "
            finalized += joiner + text
            volatile = ""
        } else {
            volatile = (finalized.isEmpty ? "" : " ") + text
        }
        onPartial?((finalized + volatile).trimmingCharacters(in: .whitespaces))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if format == nil {
                if let copy = buffer.copy() as? AVAudioPCMBuffer { pending.append(copy) }
            } else {
                feed(buffer)
            }
        }
    }

    /// Must be called with `lock` held.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format else { return }
        if buffer.format == format {
            continuation?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation?.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async throws -> String {
        lock.withLock {
            finishRequested = true
            if format != nil { continuation?.finish() } // otherwise start() finishes after flushing
        }
        // The analyzer may still be loading if the user released very quickly.
        await startTask?.value
        if let startError { reset(); throw startError }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        return text
    }

    func cancel() {
        continuation?.finish()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        resultsTask?.cancel()
        reset()
    }

    private func reset() {
        lock.withLock {
            analyzer = nil
            startTask = nil
            continuation = nil
            resultsTask = nil
            converter = nil
            format = nil
            pending.removeAll()
        }
    }
}
