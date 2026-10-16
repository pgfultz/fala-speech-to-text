import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import Speech

/// Inserts text into the frontmost app by pasting, then restores the previous clipboard.
enum Paster {
    /// Returns false when the text could only be copied (no Accessibility permission to send ⌘V).
    @discardableResult
    static func insert(_ text: String, restoreClipboard: Bool) -> Bool {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem]? = restoreClipboard ? snapshot(pb) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pb.changeCount

        guard Permissions.accessibility else { return false } // text stays on the clipboard

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(9)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pb.changeCount == changeCount else { return } // user copied something meanwhile
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
        return true
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestSpeech() async {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
    }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSettings("Privacy_Accessibility")
    }

    /// Clears a stale Accessibility entry (e.g. from an older build with a different signature)
    /// and asks again, which re-adds the current app to the list.
    static func resetAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "dev.fala.app"]
        try? p.run()
        p.waitUntilExit()
        promptAccessibility()
    }

    static func openSettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Fala: launch at login failed: \(error)")
        }
    }
}

/// Finds the Codex CLI and runs `codex login`, which opens the browser for ChatGPT sign-in.
enum CodexCLI {
    static func path() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func login(completion: @escaping (Bool) -> Void) -> Bool {
        guard let path = path() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["login"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            DispatchQueue.main.async { completion(proc.terminationStatus == 0) }
        }
        do { try p.run() } catch { return false }
        return true
    }
}

enum Sound {
    static func play(_ name: String) {
        guard AppSettings.shared.sounds else { return }
        let s = NSSound(named: NSSound.Name(name))
        s?.volume = 0.25
        s?.play()
    }
}
