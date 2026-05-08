import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox
import Combine

struct ShortcutConfig: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt64

    static let ejectKey = ShortcutConfig(keyCode: -1, modifiers: 0)

    var isEjectKey: Bool { keyCode == -1 }

    var displayString: String {
        if isEjectKey { return "⏏ Eject" }
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl)   { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift)     { parts.append("⇧") }
        if flags.contains(.maskCommand)   { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for code: Int) -> String {
        switch code {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let scalar = keyCodeToChar(code) { return String(scalar).uppercased() }
            return "Key\(code)"
        }
    }
}

private func keyCodeToChar(_ code: Int) -> Character? {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    let result = layoutData.withUnsafeBytes { ptr in
        UCKeyTranslate(
            ptr.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
            UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars
        )
    }
    guard result == noErr, length > 0 else { return nil }
    return Character(UnicodeScalar(chars[0])!)
}

class ShortcutManager: ObservableObject {
    var onToggleShortcut: (() -> Void)?

    @Published var config: ShortcutConfig {
        didSet {
            if config != oldValue { saveConfig() }
        }
    }

    @Published var isRecording = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let defaultsKey = "shortcutConfig"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = .ejectKey
        }
        setupEventTap()
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func setupEventTap() {
        let systemDefinedEventMask = UInt64(1) << 14
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        systemDefinedEventMask

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(refcon).takeUnretainedValue()

            if manager.isRecording {
                if type == .keyDown {
                    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    let modOnly: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
                    let mods = event.flags.rawValue & modOnly.rawValue
                    DispatchQueue.main.async {
                        manager.config = ShortcutConfig(keyCode: keyCode, modifiers: mods)
                        manager.isRecording = false
                    }
                    return nil
                }
                return Unmanaged.passRetained(event)
            }

            if manager.config.isEjectKey {
                if type.rawValue == 14 {
                    let nsEvent = NSEvent(cgEvent: event)
                    if let ev = nsEvent, ev.subtype.rawValue == 8 {
                        let data1 = ev.data1
                        let keyCode = (data1 & 0xFFFF0000) >> 16
                        let keyFlags = (data1 & 0x0000FFFF)
                        if keyCode == 14 && keyFlags == 0x0A {
                            manager.onToggleShortcut?()
                        }
                    }
                }
            } else if type == .keyDown {
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let modOnly: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
                let mods = event.flags.rawValue & modOnly.rawValue
                if keyCode == manager.config.keyCode && mods == manager.config.modifiers {
                    manager.onToggleShortcut?()
                    return nil
                }
            }

            return Unmanaged.passRetained(event)
        }

        let info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: CGEventMask(eventMask),
                                     callback: callback,
                                     userInfo: info)

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}
