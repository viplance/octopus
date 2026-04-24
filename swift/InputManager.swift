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
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            inputEvent = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: true, flags: flags, rawData: nil)
        case .keyUp:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            inputEvent = InputEvent(type: .keyUp, dx: nil, dy: nil, button: nil, keyCode: keyCode, isDown: false, flags: flags, rawData: nil)
        default:
            // For scroll wheels, gestures and NX_SYSDEFINED, simply serialize the event to raw binary data
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
                            currentLoc.x = max(totalBounds.minX, min(currentLoc.x, totalBounds.maxX - 1))
                            currentLoc.y = max(totalBounds.minY, min(currentLoc.y, totalBounds.maxY - 1))
                        }
                        

                    }
                    
                    rawEvent.location = currentLoc
                    rawEvent.post(tap: .cghidEventTap)
                }
            }
        case .keyDown, .keyUp:
            if let keyCode = event.keyCode, let isDown = event.isDown {
                let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
                if let flags = event.flags {
                    keyEvent?.flags = CGEventFlags(rawValue: flags)
                }
                keyEvent?.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }
}
