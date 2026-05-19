import Foundation
import CoreGraphics
import AppKit
import QuartzCore

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
    private var tapRunLoop: CFRunLoop?
    private var savedCursorPosition: CGPoint?
    private let processingQueue = DispatchQueue(label: "com.octopus.input-processing", qos: .userInteractive)

    private var batchDx: Double = 0
    private var batchDy: Double = 0
    private var batchTimer: CFRunLoopTimer?
    private static let batchInterval: CFTimeInterval = 0.008

    // Tracks which mouse button (if any) is currently held on the master so
    // that batched cursor movement can be flagged as a drag on the slave —
    // macOS apps ignore plain mouseMoved events while a button is down and
    // expect leftMouseDragged / rightMouseDragged instead.
    fileprivate var heldMouseButton: Int?

    deinit {
        stopCapture()
    }
    
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

            // When the shortcut is Eject, detect it among NX_SYSDEFINED
            // events and fire the toggle instead of forwarding.
            if type.rawValue == 14 {
                if let config = manager.shortcutConfig, config.isEjectKey,
                   let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 {
                    let data1 = nsEvent.data1
                    let sysKeyCode = (data1 & 0xFFFF0000) >> 16
                    let keyFlags = (data1 & 0x0000FFFF)
                    let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
                    if sysKeyCode == 14 && isKeyDown {
                        DispatchQueue.main.async { manager.onToggleShortcut?() }
                        return nil
                    }
                }
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

            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                if let pos = manager.savedCursorPosition {
                    CGWarpMouseCursorPosition(pos)
                }
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                let dy = event.getDoubleValueField(.mouseEventDeltaY)
                manager.accumulateMouseMove(dx: dx, dy: dy)
                return nil
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
                if let pos = manager.savedCursorPosition {
                    CGWarpMouseCursorPosition(pos)
                }
                manager.flushMouseBatch()
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                let dy = event.getDoubleValueField(.mouseEventDeltaY)
                let button: Int = (type == .rightMouseDown || type == .rightMouseUp) ? 1 : 0
                let isDown = (type == .leftMouseDown || type == .rightMouseDown)
                // Preserve macOS click-state so the slave can rebuild double/triple-clicks.
                // Without this, a fast Down/Up/Down/Up sequence is replayed as four
                // separate single clicks and apps never see a double-click.
                let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
                if isDown {
                    manager.heldMouseButton = button
                } else if manager.heldMouseButton == button {
                    manager.heldMouseButton = nil
                }
                let clickEvent = InputEvent(type: .mouseClick, dx: dx, dy: dy, button: button, keyCode: nil, isDown: isDown, flags: nil, rawData: nil, control: nil, clickCount: clickState)
                manager.onEventCaptured?(clickEvent)
                return nil
            default:
                break
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
            // Capture the tap thread's CFRunLoop so stopCapture() can call
            // CFRunLoopStop() on it. Without this, the thread leaks past app
            // termination — it holds the event-tap mach port, the kernel keeps
            // the process registered, and launchd cannot reap it. Result: a
            // zombie OctopusSync entry per session that LaunchServices keeps
            // trying to AppleEvent on next launch, eventually returning -1712.
            let runLoopReady = DispatchSemaphore(value: 0)
            let thread = Thread { [weak self] in
                self?.tapRunLoop = CFRunLoopGetCurrent()
                runLoopReady.signal()
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
            }
            thread.qualityOfService = .userInteractive
            thread.name = "com.octopus.input-tap"
            thread.start()
            tapThread = thread
            _ = runLoopReady.wait(timeout: .now() + 1.0)
        } else {
            // tapCreate returns nil when Accessibility / Input Monitoring is
            // missing. Surface this so the caller can abort sharing instead of
            // entering a half-started state where the cursor is on the peer
            // but local input never gets captured.
            DispatchQueue.main.async { [weak self] in self?.onTapBroken?() }
        }
    }

    func stopCapture() {
        flushMouseBatch()
        if let pos = savedCursorPosition {
            CGWarpMouseCursorPosition(pos)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
            runLoopSource = nil
        }
        if let loop = tapRunLoop {
            CFRunLoopStop(loop)
            tapRunLoop = nil
        }
        tapThread = nil
    }
    
    func accumulateMouseMove(dx: Double, dy: Double) {
        batchDx += dx
        batchDy += dy
        if batchTimer == nil, let loop = tapRunLoop {
            let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.batchInterval, 0, 0, 0) { [weak self] _ in
                self?.flushMouseBatch()
            }
            batchTimer = timer
            CFRunLoopAddTimer(loop, timer, .commonModes)
        }
    }

    func flushMouseBatch() {
        if let timer = batchTimer {
            CFRunLoopTimerInvalidate(timer)
            batchTimer = nil
        }
        let dx = batchDx
        let dy = batchDy
        batchDx = 0
        batchDy = 0
        guard dx != 0 || dy != 0 else { return }
        // If a mouse button is currently held, encode this batch as a drag so
        // the slave can post leftMouseDragged / rightMouseDragged. The button
        // field carries the held button index (0 = left, 1 = right).
        let moveEvent = InputEvent(type: .mouseMove, dx: dx, dy: dy, button: heldMouseButton, keyCode: nil, isDown: nil, flags: nil, rawData: nil, control: nil, clickCount: nil)
        onEventCaptured?(moveEvent)
    }

    private func handleCapturedEvent(event: CGEvent, type: CGEventType) {
        var inputEvent: InputEvent?

        switch type {
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            inputEvent = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: true, flags: flags, rawData: nil, control: nil, clickCount: nil)
        case .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            inputEvent = InputEvent(type: .keyUp, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: false, flags: flags, rawData: nil, control: nil, clickCount: nil)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let dragButton: Int? = (type == .leftMouseDragged) ? 0 : (type == .rightMouseDragged ? 1 : nil)
            inputEvent = InputEvent(type: .mouseMove, dx: dx, dy: dy, button: dragButton, keyCode: nil, isDown: nil, flags: nil, rawData: nil, control: nil, clickCount: nil)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let button: Int = (type == .rightMouseDown || type == .rightMouseUp) ? 1 : 0
            let isDown = (type == .leftMouseDown || type == .rightMouseDown)
            let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
            inputEvent = InputEvent(type: .mouseClick, dx: dx, dy: dy, button: button, keyCode: nil, isDown: isDown, flags: nil, rawData: nil, control: nil, clickCount: clickState)
        default:
            if let data = event.data {
                inputEvent = InputEvent(type: .raw, dx: nil, dy: nil, button: nil, keyCode: nil, isDown: nil, flags: nil, rawData: data as Data, control: nil, clickCount: nil)
            }
            break
        }

        if let inputEvent = inputEvent {
            onEventCaptured?(inputEvent)
        }
    }
    
    private var cachedDisplayBounds: CGRect = .null
    private var displayBoundsCacheTime: CFTimeInterval = 0

    private func screenBounds() -> CGRect {
        let now = CACurrentMediaTime()
        if now - displayBoundsCacheTime < 5.0 && !cachedDisplayBounds.isNull {
            return cachedDisplayBounds
        }
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &activeDisplays, &displayCount)
        var total = CGRect.null
        for display in activeDisplays {
            let bounds = CGDisplayBounds(display)
            total = total.isNull ? bounds : total.union(bounds)
        }
        cachedDisplayBounds = total
        displayBoundsCacheTime = now
        return total
    }

    private func clampToScreen(_ point: inout CGPoint) {
        let bounds = screenBounds()
        guard !bounds.isNull else { return }
        point.x = max(bounds.minX, min(point.x, bounds.maxX - 1))
        point.y = max(bounds.minY, min(point.y, bounds.maxY - 1))
    }

    func injectEvent(_ event: InputEvent) {
        switch event.type {
        case .mouseMove:
            let dx = event.dx ?? 0
            let dy = event.dy ?? 0
            let currentLocEvent = CGEvent(source: nil)
            var loc = currentLocEvent?.location ?? .zero
            loc.x += dx
            loc.y += dy
            clampToScreen(&loc)
            // When a mouse button is held on the master, the captured event
            // carries the held button index in `button`. We must synthesize a
            // drag event here — plain mouseMoved while a button is down is
            // dropped by AppKit drag-tracking machinery, breaking drag&drop
            // and text selection.
            let moveType: CGEventType
            let moveBtn: CGMouseButton
            if let held = event.button {
                moveType = (held == 1) ? .rightMouseDragged : .leftMouseDragged
                moveBtn = (held == 1) ? .right : .left
            } else {
                moveType = .mouseMoved
                moveBtn = .left
            }
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: moveType, mouseCursorPosition: loc, mouseButton: moveBtn) {
                moveEvent.setDoubleValueField(.mouseEventDeltaX, value: dx)
                moveEvent.setDoubleValueField(.mouseEventDeltaY, value: dy)
                moveEvent.post(tap: .cgSessionEventTap)
            }
        case .mouseClick:
            let dx = event.dx ?? 0
            let dy = event.dy ?? 0
            let isDown = event.isDown ?? true
            let isRight = (event.button ?? 0) == 1
            let currentLocEvent = CGEvent(source: nil)
            var loc = currentLocEvent?.location ?? .zero
            loc.x += dx
            loc.y += dy
            clampToScreen(&loc)
            let clickType: CGEventType
            if isRight {
                clickType = isDown ? .rightMouseDown : .rightMouseUp
            } else {
                clickType = isDown ? .leftMouseDown : .leftMouseUp
            }
            let btn: CGMouseButton = isRight ? .right : .left
            if let clickEvent = CGEvent(mouseEventSource: nil, mouseType: clickType, mouseCursorPosition: loc, mouseButton: btn) {
                // Replay the master's click-state so the slave's HIToolbox sees
                // back-to-back clicks as a double/triple click rather than as N
                // independent singles. Missing this is why double-click failed.
                if let cs = event.clickCount, cs > 0 {
                    clickEvent.setIntegerValueField(.mouseEventClickState, value: Int64(cs))
                }
                clickEvent.post(tap: .cgSessionEventTap)
            }
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
                        clampToScreen(&currentLoc)
                    }

                    rawEvent.location = currentLoc
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
                keyEvent?.post(tap: .cgSessionEventTap)
            }
        default:
            break
        }
    }
}
