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
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.leftMouseUp.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseUp.rawValue) |
                        (1 << CGEventType.scrollWheel.rawValue)
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let manager = refcon?.assumingMemoryBound(to: InputManager.self).pointee else {
                return Unmanaged.passRetained(event)
            }
            
            manager.handleCapturedEvent(event: event, type: type)
            
            // Return nil to suppress the event locally
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
            inputEvent = InputEvent(type: .mouseMove, dx: dx, dy: dy, button: nil, keyCode: nil, isDown: nil)
        case .leftMouseDown, .rightMouseDown:
            let button = type == .leftMouseDown ? 0 : 1
            inputEvent = InputEvent(type: .mouseClick, dx: nil, dy: nil, button: button, keyCode: nil, isDown: true)
        case .leftMouseUp, .rightMouseUp:
            let button = type == .leftMouseUp ? 0 : 1
            inputEvent = InputEvent(type: .mouseClick, dx: nil, dy: nil, button: button, keyCode: nil, isDown: false)
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            inputEvent = InputEvent(type: .scroll, dx: dx, dy: dy, button: nil, keyCode: nil, isDown: nil)
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            inputEvent = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: true)
        case .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            inputEvent = InputEvent(type: .keyUp, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: false)
        default:
            break
        }
        
        if let inputEvent = inputEvent {
            onEventCaptured?(inputEvent)
        }
    }
    
    func injectEvent(_ event: InputEvent) {
        switch event.type {
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
