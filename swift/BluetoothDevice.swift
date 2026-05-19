import Foundation

struct BluetoothDevice: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let type: DeviceType
    var isSelected: Bool = false
    var registryIDs: Set<UInt64> = []

    init(name: String, type: DeviceType, isSelected: Bool = false, registryIDs: Set<UInt64> = []) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.isSelected = isSelected
        self.registryIDs = registryIDs
    }

    enum DeviceType: String, Codable {
        case keyboard
        case mouse
        case touchpad
        case other
    }
}
