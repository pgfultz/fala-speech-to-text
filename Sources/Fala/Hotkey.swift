import AppKit
import Carbon.HIToolbox

/// A global shortcut: a main key plus required modifiers. The main key may itself be a
/// modifier (e.g. Right ⌥ alone, or fn), which makes it a "modifier-only" shortcut.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let `default` = Shortcut(keyCode: 61, modifiers: 0) // Right Option

    static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    static let modifierKeys: [UInt16: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        56: .maskShift, 60: .maskShift,
        63: .maskSecondaryFn,
    ]

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }
    var isModifierOnly: Bool { Shortcut.modifierKeys[keyCode] != nil }
    /// All modifier flags that must be held (including the key's own flag when modifier-only).
    var targetFlags: CGEventFlags { flags.union(Shortcut.modifierKeys[keyCode] ?? []) }

    /// Keycap labels, e.g. ["⌃", "⌥", "Espaço"].
    var parts: [String] {
        var out: [String] = []
        let f = flags
        if f.contains(.maskSecondaryFn) { out.append("fn") }
        if f.contains(.maskControl) { out.append("⌃") }
        if f.contains(.maskAlternate) { out.append("⌥") }
        if f.contains(.maskShift) { out.append("⇧") }
        if f.contains(.maskCommand) { out.append("⌘") }
        out.append(KeyNames.name(for: keyCode, sided: modifiers == 0))
        return out
    }

    var display: String { parts.joined(separator: " ") }
}

enum KeyNames {
    static func name(for code: UInt16, sided: Bool = true) -> String {
        switch Int(code) {
        case 54: return sided ? "⌘ direito" : "⌘"
        case 55: return sided ? "⌘ esquerdo" : "⌘"
        case 58: return sided ? "⌥ esquerdo" : "⌥"
        case 61: return sided ? "⌥ direito" : "⌥"
        case 59: return sided ? "⌃ esquerdo" : "⌃"
        case 62: return sided ? "⌃ direito" : "⌃"
        case 56: return sided ? "⇧ esquerdo" : "⇧"
        case 60: return sided ? "⇧ direito" : "⇧"
        case 63: return "fn 🌐"
        case kVK_Space: return "Espaço"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_CapsLock: return "⇪"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
        case kVK_F16: return "F16"; case kVK_F17: return "F17"; case kVK_F18: return "F18"
        case kVK_F19: return "F19"; case kVK_F20: return "F20"
        default: return translate(code) ?? "#\(code)"
        }
    }

    private static func translate(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Listens to keyboard events system-wide through a CGEventTap (requires Accessibility).
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    var shortcut: Shortcut = AppSettings.shared.shortcut { didSet { isDown = false } }
    var paused = false
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Another key was typed while a modifier-only shortcut is held (e.g. ⌥+E for an accent).
    var onInterrupt: () -> Void = {}
    /// Return true to swallow the Escape key.
    var onEscape: () -> Bool = { false }

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if paused { return pass }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(Shortcut.relevant)

        if shortcut.isModifierOnly {
            if type == .flagsChanged {
                let target = shortcut.targetFlags
                if shortcut.modifiers == 0 {
                    // Single modifier: match the physical key so left/right sides are distinct.
                    guard code == shortcut.keyCode else {
                        if isDown { fire(onInterrupt) }
                        return pass
                    }
                    let own = Shortcut.modifierKeys[code]!
                    if flags.contains(own), !isDown, flags == own {
                        isDown = true
                        fire(onPress)
                    } else if !flags.contains(own), isDown {
                        isDown = false
                        fire(onRelease)
                    }
                } else {
                    if !isDown, flags == target {
                        isDown = true
                        fire(onPress)
                    } else if isDown, !flags.contains(target) {
                        isDown = false
                        fire(onRelease)
                    }
                }
                // Swallow fn so macOS does not pop the emoji picker / system dictation.
                if code == 63, shortcut.keyCode == 63 { return nil }
                return pass
            }
            if type == .keyDown, isDown {
                fire(onInterrupt)
            }
        } else if code == shortcut.keyCode, type == .keyDown || type == .keyUp {
            var actual = flags
            if !shortcut.flags.contains(.maskSecondaryFn) { actual.remove(.maskSecondaryFn) }
            if type == .keyDown, actual == shortcut.flags {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isDown, !isRepeat {
                    isDown = true
                    fire(onPress)
                }
                return nil
            }
            if type == .keyUp, isDown {
                isDown = false
                fire(onRelease)
                return nil
            }
        }

        if type == .keyDown, code == UInt16(kVK_Escape), onEscape() { return nil }
        return pass
    }

    private func fire(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}
