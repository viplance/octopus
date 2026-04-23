import Foundation

struct InputEvent: Codable, Sendable {
    let type: EventType
    let dx: Double?
    let dy: Double?
    let button: Int?
    let keyCode: Int?
    let isDown: Bool?
    
    enum EventType: Int, Codable, Sendable {
        case mouseMove
        case mouseClick
        case scroll
        case keyDown
        case keyUp
    }
}
