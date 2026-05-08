import Foundation

struct BluetoothDevice: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let type: DeviceType
    var isSelected: Bool = false

    init(name: String, type: DeviceType, isSelected: Bool = false) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.isSelected = isSelected
    }

    enum DeviceType: String, Codable {
        case keyboard
        case mouse
        case touchpad
        case other
    }
}
