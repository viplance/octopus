import Foundation

struct BluetoothDevice: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let type: DeviceType
    var isSelected: Bool = false
    
    enum DeviceType {
        case keyboard
        case mouse
        case touchpad
        case other
    }
}
