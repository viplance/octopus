import Foundation
import IOKit.hid
import Combine

class DeviceManager: ObservableObject {
    @Published var devices: [BluetoothDevice] = []
    private var hidManager: IOHIDManager?
    
    init() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    
    func refreshDevices() {
        guard let hidManager = hidManager else { return }
        
        // Define criteria for HID devices
        let multipleCriteria: [CFDictionary] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
            ] as CFDictionary,
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
            ] as CFDictionary,
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Pointer
            ] as CFDictionary
        ]
        
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, multipleCriteria as CFArray)
        
        // We don't need to open the manager just to enumerate the devices.
        // Opening it might fail if Input Monitoring permissions aren't fully granted yet, 
        // causing the list to be empty.
        
        guard let hidDevicesSet = IOHIDManagerCopyDevices(hidManager) as NSSet?,
              let hidDevices = hidDevicesSet.allObjects as? [IOHIDDevice] else {
            DispatchQueue.main.async {
                self.devices = []
            }
            return
        }
        
        var newDevices: [BluetoothDevice] = []
        for device in hidDevices {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown Device"
            
            // Check if it's a Bluetooth device (often has a transport type of Bluetooth)
            _ = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            
            // We allow Apple Internal devices so the user can share their MacBook keyboard/trackpad.
            // if name.contains("Internal") || name.contains("Built-in") {
            //     continue
            // }
            
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            
            var type: BluetoothDevice.DeviceType = .other
            if usagePage == kHIDPage_GenericDesktop {
                if usage == kHIDUsage_GD_Keyboard {
                    type = .keyboard
                } else if usage == kHIDUsage_GD_Mouse {
                    type = .mouse
                } else if usage == kHIDUsage_GD_Pointer {
                    type = .touchpad
                }
            }
            
            let btDevice = BluetoothDevice(name: name, type: type)
            // Prevent duplicates (some devices register multiple interfaces)
            if !newDevices.contains(where: { $0.name == name && $0.type == type }) {
                newDevices.append(btDevice)
            }
        }
        
        DispatchQueue.main.async {
            self.devices = newDevices
        }
    }
}
