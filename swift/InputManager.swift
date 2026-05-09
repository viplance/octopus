import Foundation
import CoreGraphics

class InputManager {
    var onEventCaptured: ((InputEvent) -> Void)?
    var onToggleShortcut: (() -> Void)?
    // Fired when the event tap dies and cannot be revived (typically because
    // Accessibility or Input Monitoring was revoked). The owner must stop
    // capture and return local control to the user, otherwise the OS keeps
    // routing input through a dead tap and the machine appears frozen.
    var onTapBroken: (() -> Void)?
    var shortcutConfig: ShortcutConfig?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var savedCursorPosition: CGPoint?
    private let processingQueue = DispatchQueue(label: "com.octopus.input-processing", qos: .userInteractive)
    
    func startCapture(devices: [BluetoothDevice]) {
        guard !devices.isEmpty else { return }
        
        let locEvent = CGEvent(source: nil)
        savedCursorPosition = locEvent?.location
        
        // In a full implementation, we would selectively filter based on device ID.
        // For standard CGEventTap, it's global. We capture user input and suppress it locally.
        
        let eventTypes: [UInt64] = [
            UInt64(1) << CGEventType.keyDown.rawValue,
            UInt64(1) << CGEventType.keyUp.rawValue,
            UInt64(1) << CGEventType.mouseMoved.rawValue,
            UInt64(1) << CGEventType.leftMouseDragged.rawValue,
            UInt64(1) << CGEventType.rightMouseDragged.rawValue,
            UInt64(1) << CGEventType.leftMouseDown.rawValue,
            UInt64(1) << CGEventType.leftMouseUp.rawValue,
            UInt64(1) << CGEventType.rightMouseDown.rawValue,
            UInt64(1) << CGEventType.rightMouseUp.rawValue,
            UInt64(1) << CGEventType.scrollWheel.rawValue,
            UInt64(1) << 14, // NX_SYSDEFINED (volume, media)
            UInt64(1) << 29, // NSEventTypeGesture
            UInt64(1) << 30, // NSEventTypeMagnify
            UInt64(1) << 31, // NSEventTypeSwipe
            UInt64(1) << 18, // NSEventTypeRotate
            UInt64(1) << 19, // NSEventTypeBeginGesture
            UInt64(1) << 20, // NSEventTypeEndGesture
            UInt64(1) << 32, // NSEventTypeSmartMagnify
            UInt64(1) << CGEventType.flagsChanged.rawValue
        ]
        let eventMask = eventTypes.reduce(0, |)
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<InputManager>.fromOpaque(refcon).takeUnretainedValue()

            // The system disables our tap when the screen is locked, the
            // loginwindow takes over, or the user revokes Accessibility /
            // Input Monitoring. Re-enable so we keep intercepting in the
            // first two cases — but if the tap stays disabled, the permission
            // is gone and we MUST hand control back to the user, otherwise
            // their keyboard/mouse appear frozen because we are still
            // returning nil for every event below.
            if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    if !CGEvent.tapIsEnabled(tap: tap) {
                        DispatchQueue.main.async { manager.onTapBroken?() }
                    }
                }
                return Unmanaged.passRetained(event)
            }

            // NX_SYSDEFINED events (volume, brightness, media, eject) pass
            // through so they act locally. When the shortcut is eject key,
            // ShortcutManager (on the main thread) handles toggle detection.
            if type.rawValue == 14 {
                return Unmanaged.passRetained(event)
            }

            if let config = manager.shortcutConfig, !config.isEjectKey, type == .keyDown {
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let modOnly: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
                let mods = event.flags.rawValue & modOnly.rawValue
                if keyCode == config.keyCode && mods == config.modifiers {
                    DispatchQueue.main.async { manager.onToggleShortcut?() }
                    return nil
                }
            }

            if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged {
                if let pos = manager.savedCursorPosition {
                    CGWarpMouseCursorPosition(pos)
                }
            }

            let retainedEvent = Unmanaged.passRetained(event)
            let eventType = type
            manager.processingQueue.async {
                let cgEvent = retainedEvent.takeRetainedValue()
                manager.handleCapturedEvent(event: cgEvent, type: eventType)
            }

            return nil
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
            let source = runLoopSource!
            let thread = Thread {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
            }
            thread.qualityOfService = .userInteractive
            thread.name = "com.octopus.input-tap"
            thread.start()
            tapThread = thread
        } else {
            // tapCreate returns nil when Accessibility / Input Monitoring is
            // missing. Surface this so the caller can abort sharing instead of
            // entering a half-started state where the cursor is on the peer
            // but local input never gets captured.
            DispatchQueue.main.async { [weak self] in self?.onTapBroken?() }
        }
    }

    func stopCapture() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        runLoopSource = nil
        tapThread = nil
    }
    
    private func handleCapturedEvent(event: CGEvent, type: CGEventType) {
        var inputEvent: InputEvent?
        
        switch type {
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            inputEvent = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: true, flags: flags, rawData: nil, control: nil)
        case .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            inputEvent = InputEvent(type: .keyUp, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: false, flags: flags, rawData: nil, control: nil)
        default:
            // For scroll wheels, gestures and NX_SYSDEFINED, simply serialize the event to raw binary data
            if let data = event.data {
                inputEvent = InputEvent(type: .raw, dx: nil, dy: nil, button: nil, keyCode: nil, isDown: nil, flags: nil, rawData: data as Data, control: nil)
            }
            break
        }
        
        if let inputEvent = inputEvent {
            onEventCaptured?(inputEvent)
        }
    }
    
    func injectEvent(_ event: InputEvent) {
        switch event.type {
        case .raw:
            if let data = event.rawData as CFData? {
                if let rawEvent = CGEvent(withDataAllocator: kCFAllocatorDefault, data: data) {
                    let rawType = rawEvent.type
                    let currentLocEvent = CGEvent(source: nil)
                    var currentLoc = currentLocEvent?.location ?? .zero

                    if rawType == .mouseMoved || rawType == .leftMouseDragged || rawType == .rightMouseDragged ||
                       rawType == .leftMouseDown || rawType == .leftMouseUp || rawType == .rightMouseDown || rawType == .rightMouseUp {

                        var dx: Double = 0
                        var dy: Double = 0

                        if rawType == .mouseMoved || rawType == .leftMouseDragged || rawType == .rightMouseDragged {
                            dx = rawEvent.getDoubleValueField(.mouseEventDeltaX)
                            dy = rawEvent.getDoubleValueField(.mouseEventDeltaY)
                        }

                        currentLoc.x += dx
                        currentLoc.y += dy

                        var displayCount: UInt32 = 0
                        CGGetActiveDisplayList(0, nil, &displayCount)
                        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
                        CGGetActiveDisplayList(displayCount, &activeDisplays, &displayCount)

                        var totalBounds = CGRect.null
                        for display in activeDisplays {
                            let bounds = CGDisplayBounds(display)
                            totalBounds = totalBounds.isNull ? bounds : totalBounds.union(bounds)
                        }

                        if !totalBounds.isNull {
                            currentLoc.x = max(totalBounds.minX, min(currentLoc.x, totalBounds.maxX - 1))
                            currentLoc.y = max(totalBounds.minY, min(currentLoc.y, totalBounds.maxY - 1))
                        }
                    }

                    rawEvent.location = currentLoc
                    // Post at session level so events reach the login window / password fields.
                    // cghidEventTap alone does not penetrate the loginwindow's security session.
                    rawEvent.post(tap: .cgSessionEventTap)
                }
            }
        case .keyDown, .keyUp:
            if let keyCode = event.keyCode, let isDown = event.isDown {
                let src = CGEventSource(stateID: .combinedSessionState)
                let keyEvent = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
                if let flags = event.flags {
                    keyEvent?.flags = CGEventFlags(rawValue: flags)
                }
                // Post at session level — reaches loginwindow password field.
                // Also ensure the keyboard state tracks correctly for modifier keys.
                keyEvent?.post(tap: .cgSessionEventTap)
            }
        default:
            break
        }
    }
}
