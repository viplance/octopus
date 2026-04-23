import Foundation
import CoreGraphics

class InputManager {
    var onEventCaptured: ((InputEvent) -> Void)?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    func startCapture(devices: [BluetoothDevice]) {
        guard !devices.isEmpty else { return }
        
        // In a full implementation, we would selectively filter based on device ID.
        // For standard CGEventTap, it's global. We capture user input and suppress it locally.
        
        let eventTypes: [UInt64] = [
            UInt64(1) << CGEventType.keyDown.rawValue,
            UInt64(1) << CGEventType.keyUp.rawValue,
            UInt64(1) << CGEventType.mouseMoved.rawValue,
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
            UInt64(1) << 32  // NSEventTypeSmartMagnify
        ]
        let eventMask = eventTypes.reduce(0, |)
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let manager = refcon?.assumingMemoryBound(to: InputManager.self).pointee else {
                return Unmanaged.passRetained(event)
            }
            
            manager.handleCapturedEvent(event: event, type: type)
            
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
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    
    func stopCapture() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
    }
    
    private func handleCapturedEvent(event: CGEvent, type: CGEventType) {
        var inputEvent: InputEvent?
        
        switch type {
        case .mouseMoved:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            inputEvent = InputEvent(type: .mouseMove, dx: dx, dy: dy, button: nil, keyCode: nil, isDown: nil, rawData: nil)
        case .leftMouseDown, .rightMouseDown:
            let button = type == .leftMouseDown ? 0 : 1
            inputEvent = InputEvent(type: .mouseClick, dx: nil, dy: nil, button: button, keyCode: nil, isDown: true, rawData: nil)
        case .leftMouseUp, .rightMouseUp:
            let button = type == .leftMouseUp ? 0 : 1
            inputEvent = InputEvent(type: .mouseClick, dx: nil, dy: nil, button: button, keyCode: nil, isDown: false, rawData: nil)
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            inputEvent = InputEvent(type: .scroll, dx: dx, dy: dy, button: nil, keyCode: nil, isDown: nil, rawData: nil)
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            inputEvent = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: true, rawData: nil)
        case .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            inputEvent = InputEvent(type: .keyUp, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: false, rawData: nil)
        default:
            // For gestures and NX_SYSDEFINED, simply serialize the event to raw binary data
            if let data = event.data {
                inputEvent = InputEvent(type: .raw, dx: nil, dy: nil, button: nil, keyCode: nil, isDown: nil, rawData: data as Data)
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
                    rawEvent.post(tap: .cghidEventTap)
                }
            }
        case .mouseMove:
            if let dx = event.dx, let dy = event.dy {
                var mouseLoc = CGEvent(source: nil)?.location ?? .zero
                mouseLoc.x += dx
                mouseLoc.y += dy
                
                // Clamp to screen bounds
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
                    mouseLoc.x = max(totalBounds.minX, min(mouseLoc.x, totalBounds.maxX - 1))
                    mouseLoc.y = max(totalBounds.minY, min(mouseLoc.y, totalBounds.maxY - 1))
                }
                let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: mouseLoc, mouseButton: .left)
                moveEvent?.post(tap: .cghidEventTap)
            }
        case .mouseClick:
            if let button = event.button, let isDown = event.isDown {
                let mouseLoc = CGEvent(source: nil)?.location ?? .zero
                let type: CGEventType
                let mouseButton: CGMouseButton
                if button == 0 {
                    type = isDown ? .leftMouseDown : .leftMouseUp
                    mouseButton = .left
                } else {
                    type = isDown ? .rightMouseDown : .rightMouseUp
                    mouseButton = .right
                }
                let clickEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: mouseLoc, mouseButton: mouseButton)
                // Fix window selection bug by explicitly setting the click state
                clickEvent?.setIntegerValueField(.mouseEventClickState, value: 1)
                clickEvent?.post(tap: .cghidEventTap)
            }
        case .scroll:
             if let dy = event.dy {
                 let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
                 scrollEvent?.post(tap: .cghidEventTap)
             }
        case .keyDown, .keyUp:
            if let keyCode = event.keyCode, let isDown = event.isDown {
                let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
                keyEvent?.post(tap: .cghidEventTap)
            }
        }
    }
}
