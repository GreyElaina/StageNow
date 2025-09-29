import Foundation

struct SpaceStatusEntry: Codable {
    let id: UInt64
    let order: Int?
    let uuid: String?
    let description: String
    let enabled: Bool

    init(id: UInt64, order: Int?, uuid: String?, description: String, enabled: Bool) {
        self.id = id
        self.order = order
        self.uuid = uuid
        self.description = description
        self.enabled = enabled
    }

    func toPropertyList() -> [String: NSObject] {
        var dictionary: [String: NSObject] = [
            "id": NSNumber(value: id),
            "enabled": NSNumber(value: enabled)
        ]

        if let order {
            dictionary["order"] = NSNumber(value: order)
        }

        if let uuid {
            dictionary["uuid"] = uuid as NSString
        }

        dictionary["description"] = description as NSString
        return dictionary
    }

    static func fromPropertyList(_ value: Any) -> SpaceStatusEntry? {
        guard let dict = dictionaryFromPropertyList(value) else {
            return nil
        }

        guard let idValue = dict["id"] else {
            return nil
        }

        let id: UInt64
        if let number = idValue as? NSNumber {
            id = number.uint64Value
        } else if let intValue = idValue as? UInt64 {
            id = intValue
        } else if let stringValue = idValue as? String, let parsed = UInt64(stringValue) {
            id = parsed
        } else {
            return nil
        }

        var order: Int?
        if let orderValue = dict["order"] {
            if let number = orderValue as? NSNumber {
                order = number.intValue
            } else if let intValue = orderValue as? Int {
                order = intValue
            } else if let stringValue = orderValue as? String, let parsed = Int(stringValue) {
                order = parsed
            }
        }

        var uuid: String?
        if let uuidValue = dict["uuid"] {
            if let stringValue = uuidValue as? String {
                uuid = stringValue
            } else if let nsStringValue = uuidValue as? NSString {
                uuid = nsStringValue as String
            }
        }

        let enabledValue = dict["enabled"]
        let enabled: Bool
        if let number = enabledValue as? NSNumber {
            enabled = number.boolValue
        } else if let boolValue = enabledValue as? Bool {
            enabled = boolValue
        } else if let stringValue = enabledValue as? String {
            enabled = (stringValue as NSString).boolValue
        } else {
            enabled = false
        }

        let description: String
        if let descriptionValue = dict["description"] as? String {
            description = descriptionValue
        } else if let nsStringValue = dict["description"] as? NSString {
            description = nsStringValue as String
        } else {
            description = "#? [id \(id)]"
        }

        return SpaceStatusEntry(id: id, order: order, uuid: uuid, description: description, enabled: enabled)
    }
}

struct CurrentSpaceStatus: Codable {
    let enabled: Bool
    let space: Int?

    init(enabled: Bool, hint: Int? = nil) {
        self.enabled = enabled
        self.space = hint
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case space
        case spaceEntry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decode(Bool.self, forKey: .enabled)
        let spaceHint = try container.decodeIfPresent(Int.self, forKey: .space)

        self.init(enabled: enabled, hint: spaceHint)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)

        if let space {
            try container.encode(space, forKey: .space)
        }
    }

    func toPropertyList() -> [String: NSObject] {
        var dictionary: [String: NSObject] = [
            "enabled": NSNumber(value: enabled)
        ]

        if let space {
            dictionary["space"] = NSNumber(value: space)
        }

        return dictionary
    }

    static func fromPropertyList(_ value: Any) -> CurrentSpaceStatus? {
        guard let dict = dictionaryFromPropertyList(value) else {
            return nil
        }

        guard let enabledValue = dict["enabled"] else {
            return nil
        }

        let enabled: Bool
        if let number = enabledValue as? NSNumber {
            enabled = number.boolValue
        } else if let boolValue = enabledValue as? Bool {
            enabled = boolValue
        } else if let stringValue = enabledValue as? String {
            enabled = (stringValue as NSString).boolValue
        } else {
            return nil
        }

        var spaceHint: Int?
        if let intValue = dict["space"] as? Int {
            spaceHint = intValue
        }

        return CurrentSpaceStatus(enabled: enabled, hint: spaceHint)
    }
}

struct SpaceStatusSnapshot: Codable {
    let current: CurrentSpaceStatus
    let spaces: [SpaceStatusEntry]

    init(current: CurrentSpaceStatus, spaces: [SpaceStatusEntry]) {
        self.current = current
        self.spaces = spaces
    }

    func toPropertyList() -> [String: NSObject] {
        let spacesArray = spaces.map { $0.toPropertyList() } as NSArray
        return [
            "current": current.toPropertyList() as NSDictionary,
            "spaces": spacesArray
        ]
    }

    static func fromPropertyList(_ value: Any) -> SpaceStatusSnapshot? {
        guard let dict = dictionaryFromPropertyList(value) else {
            return nil
        }

        guard let currentValue = dict["current"], let current = CurrentSpaceStatus.fromPropertyList(currentValue) else {
            return nil
        }

        var entries: [SpaceStatusEntry] = []
        if let spacesValue = dict["spaces"] {
            if let array = spacesValue as? [Any] {
                entries = array.compactMap { SpaceStatusEntry.fromPropertyList($0) }
            } else if let nsArray = spacesValue as? NSArray {
                entries = nsArray.compactMap { SpaceStatusEntry.fromPropertyList($0) }
            }
        }

        return SpaceStatusSnapshot(current: current, spaces: entries)
    }
}

private func dictionaryFromPropertyList(_ value: Any) -> [String: Any]? {
    if let dict = value as? [String: Any] {
        return dict
    }

    if let nsDict = value as? NSDictionary {
        var result: [String: Any] = [:]
        for case let (key as String, value) in nsDict {
            result[key] = value
        }
        return result
    }

    return nil
}
