import Foundation

struct InputEvent: Codable, Sendable {
    let type: EventType
    let dx: Double?
    let dy: Double?
    let button: Int?
    let keyCode: Int?
    let isDown: Bool?
    let flags: UInt64?
    let rawData: Data?
    let control: String?
    let clickCount: Int?
    // CACurrentMediaTime() on sender — used to measure end-to-end latency.
    // Nil for events that predate this field (old builds on the other Mac).
    let sentAt: Double?

    enum EventType: Int, Codable, Sendable {
        case mouseMove
        case mouseClick
        case scroll
        case keyDown
        case keyUp
        case raw
    }

    // Memberwise init with sentAt defaulting to nil so existing call sites
    // that omit it still compile without changes.
    init(type: EventType, dx: Double?, dy: Double?, button: Int?,
         keyCode: Int?, isDown: Bool?, flags: UInt64?, rawData: Data?,
         control: String?, clickCount: Int?, sentAt: Double? = nil) {
        self.type = type; self.dx = dx; self.dy = dy; self.button = button
        self.keyCode = keyCode; self.isDown = isDown; self.flags = flags
        self.rawData = rawData; self.control = control; self.clickCount = clickCount
        self.sentAt = sentAt
    }

    // Decode with sentAt missing in older wire format → nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type       = try c.decode(EventType.self, forKey: .type)
        dx         = try c.decodeIfPresent(Double.self,  forKey: .dx)
        dy         = try c.decodeIfPresent(Double.self,  forKey: .dy)
        button     = try c.decodeIfPresent(Int.self,     forKey: .button)
        keyCode    = try c.decodeIfPresent(Int.self,     forKey: .keyCode)
        isDown     = try c.decodeIfPresent(Bool.self,    forKey: .isDown)
        flags      = try c.decodeIfPresent(UInt64.self,  forKey: .flags)
        rawData    = try c.decodeIfPresent(Data.self,    forKey: .rawData)
        control    = try c.decodeIfPresent(String.self,  forKey: .control)
        clickCount = try c.decodeIfPresent(Int.self,     forKey: .clickCount)
        sentAt     = try c.decodeIfPresent(Double.self,  forKey: .sentAt)
    }
}
