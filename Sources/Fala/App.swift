import AppKit
import AVFoundation
import SwiftUI

@main
enum FalaMain {
    static let delegate = AppDelegate()

    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
            selfTest(file: CommandLine.arguments[i + 1])
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// `Fala --transcribe file.wav [lang]`: transcribes a file with the ChatGPT engine and exits.
private func selfTest(file: String) -> Never {
    let args = CommandLine.arguments
    let lang = args.last.flatMap { $0.count == 2 ? $0 : nil } ?? "auto"
    Task {
        do {
            let start = Date()
            let text: String
            if args.contains("--apple") {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: file))
                print("modelo:", await AppleTranscriber.modelState(language: lang == "auto" ? "pt" : lang))
                let apple = AppleTranscriber()
                apple.start(language: lang == "auto" ? "pt" : lang)
                while file.framePosition < file.length,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) {
                    try file.read(into: buffer)
                    apple.append(buffer)
                }
                text = try await apple.finish()
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                text = try await ChatGPTTranscriber.transcribe(wav: data, language: lang)
            }
            print(String(format: "OK (%.2fs): %@", Date().timeIntervalSince(start), text))
            exit(0)
        } catch {
            print("ERRO: \(error.localizedDescription) — \(error)")
            exit(1)
        }
    }
    dispatchMain()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var tapRetry: Timer?
    private let settings = AppSettings.shared
    private let controller = DictationController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        _ = OverlayController.shared
        wireHotkey()
        observePhase()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snap"), i + 1 < args.count { startSnapshots(to: args[i + 1]) }
        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.controller.demo(partialText: args.contains("--partial")) }
        } else if args.contains("--settings") {
            showSettings()
        } else if !settings.onboarded || args.contains("--onboarding") {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Hotkey

    private func wireHotkey() {
        let monitor = HotkeyMonitor.shared
        monitor.shortcut = settings.shortcut
        monitor.onPress = { [weak self] in self?.controller.hotkeyPressed() }
        monitor.onRelease = { [weak self] in self?.controller.hotkeyReleased() }
        monitor.onInterrupt = { [weak self] in self?.controller.hotkeyInterrupted() }
        monitor.onEscape = { [weak self] in self?.controller.escape() ?? false }
        if !monitor.start() {
            // Accessibility not granted yet: keep trying quietly until it is.
            tapRetry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                if Permissions.accessibility, monitor.start() {
                    t.invalidate()
                    self?.tapRetry = nil
                }
            }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(listening: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func setIcon(listening: Bool) {
        let name = listening ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Fala")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func observePhase() {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let p = self.controller.phase
                self.setIcon(listening: p == .listening || p == .transcribing)
                self.observePhase()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "Segure \(settings.shortcut.display) para falar",
                                                    attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                 .foregroundColor: NSColor.secondaryLabelColor])
        header.isEnabled = false
        menu.addItem(header)
        if !Permissions.accessibility {
            menu.addItem(item("⚠︎ Permitir Acessibilidade…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        for engine in Engine.allCases {
            let i = item(engine.title, #selector(selectEngine(_:)))
            i.representedObject = engine.rawValue
            i.state = settings.engine == engine ? .on : .off
            i.image = NSImage(systemSymbolName: engine.symbol, accessibilityDescription: nil)
            menu.addItem(i)
        }
        if settings.engine == .chatgpt {
            let account = CodexAuth.profile()
            let info = NSMenuItem(title: account?.email ?? "Não conectado — abra Ajustes", action: nil, keyEquivalent: "")
            info.isEnabled = false
            info.indentationLevel = 1
            menu.addItem(info)
        }
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Recentes", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if settings.history.isEmpty {
            let empty = NSMenuItem(title: "Nada ainda", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for h in settings.history.prefix(10) {
                let title = h.text.count > 60 ? String(h.text.prefix(60)) + "…" : h.text
                let i = item(title, #selector(copyRecent(_:)))
                i.representedObject = h.text
                i.toolTip = "Clique para copiar"
                sub.addItem(i)
            }
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Ajustes…", #selector(openSettings), key: ","))
        menu.addItem(item("Configuração inicial…", #selector(openOnboarding)))
        menu.addItem(.separator())
        menu.addItem(item("Sair do Fala", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let e = Engine(rawValue: raw) { settings.engine = e }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { Paster.copy(text) }
    }

    @objc private func openAccessibility() { Permissions.promptAccessibility() }
    @objc private func openSettings() { showSettings() }
    @objc private func openOnboarding() { showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(reopenOnboarding: { [weak self] in
                self?.settingsWindow?.close()
                self?.showOnboarding()
            })
            let w = makeWindow(NSHostingController(rootView: view), title: "Ajustes do Fala")
            w.styleMask.insert(.resizable)
            settingsWindow = w
        }
        present(settingsWindow!)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(finish: { [weak self] in self?.onboardingWindow?.close() })
            let w = makeWindow(NSHostingController(rootView: view), title: "Bem-vindo ao Fala")
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            onboardingWindow = w
        }
        present(onboardingWindow!)
    }

    private func makeWindow(_ controller: NSViewController, title: String) -> NSWindow {
        let w = NSWindow(contentViewController: controller)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === onboardingWindow { onboardingWindow = nil }
        if closing === settingsWindow { settingsWindow = nil }
        DispatchQueue.main.async {
            if self.settingsWindow == nil && self.onboardingWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Debug aid: periodically writes PNGs of the app's own windows (no screen-recording permission needed).
    private func startSnapshots(to dir: String) {
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            n += 1
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard w.windowNumber > 0, let image = Self.captureWindow(CGWindowID(truncatingIfNeeded: w.windowNumber)) else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "w%d-%03d.png", i, n))
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()

    private static func captureWindow(_ id: CGWindowID) -> CGImage? {
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        createImage?(.null, 8, id, 1)?.takeRetainedValue()
    }
}
