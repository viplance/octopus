import Foundation
import IOKit.hid
import Combine

class DeviceManager: ObservableObject {
    @Published var devices: [BluetoothDevice] = []
    private var hidManager: IOHIDManager?
    // Serial background queue so IOHID calls never run on the main thread.
    // On recent macOS, IOHIDManagerSetDeviceMatchingMultiple can block for
    // seconds inside AppleSyntheticGameController's IOServiceOpen — running
    // it on main makes the app "Not responding" at launch.
    private let hidQueue = DispatchQueue(label: "enotix.OctopusSync.hid", qos: .userInitiated)

    init() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        if let mgr = hidManager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func refreshDevices() {
        hidQueue.async { [weak self] in
            self?.refreshDevicesSync()
        }
    }

    private func refreshDevicesSync() {
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
            
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let isInternal = name.contains("Internal") || name.contains("Built-in")
                || transport == "SPI" || transport == "I2C"
            if isInternal { continue }
            
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
            
            let service = IOHIDDeviceGetService(device)
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            
            if let index = newDevices.firstIndex(where: { $0.name == name && $0.type == type }) {
                newDevices[index].registryIDs.insert(registryID)
            } else {
                let btDevice = BluetoothDevice(name: name, type: type, isSelected: false, registryIDs: [registryID])
                newDevices.append(btDevice)
            }
        }
        
        DispatchQueue.main.async {
            self.devices = newDevices
        }
    }
}
