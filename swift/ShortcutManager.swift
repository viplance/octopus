import Foundation
import CoreGraphics
import AppKit

class ShortcutManager {
    var onToggleShortcut: (() -> Void)?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    init() {
        setupShortcutListener()
    }
    
    private func setupShortcutListener() {
        let systemDefinedEventMask = UInt64(1) << 14
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | systemDefinedEventMask
        
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let manager = refcon?.assumingMemoryBound(to: ShortcutManager.self).pointee else {
                return Unmanaged.passRetained(event)
            }
            
            // Check for Eject key (systemDefined event with subtype 8)
            if type.rawValue == 14 {
                let nsEvent = NSEvent(cgEvent: event)
                if let event = nsEvent, event.subtype.rawValue == 8 {
                    let data1 = event.data1
                    let keyCode = (data1 & 0xFFFF0000) >> 16
                    let keyFlags = (data1 & 0x0000FFFF)
                    
                    // keyCode 14 is Eject
                    // keyFlags 0x0A is key down, 0x0B is key up
                    if keyCode == 14 && keyFlags == 0x0A {
                        manager.onToggleShortcut?()
                    }
                }
            }
            
            return Unmanaged.passRetained(event)
        }
        
        let info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap,
                                     place: .headInsertEventTap,
                                     options: .listenOnly,
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
