import Foundation

struct StageManagerConfig: Codable {
    let enabledSpaces: [String]

    init(enabledSpaces: [String] = []) {
        self.enabledSpaces = enabledSpaces
    }
}

struct ConfigurationChange {
    let spaceId: UInt64?
    let isEnabled: Bool?
    let enabledSpaces: Set<UInt64>
}

final class Configuration {
    private var enabledSpaces: Set<UInt64>
    private var observers: [UUID: (ConfigurationChange) -> Void] = [:]
    private let queue = DispatchQueue(label: "com.stagenow.configuration")

    init(initialSpaces: Set<UInt64> = []) {
        self.enabledSpaces = initialSpaces
    }

    @discardableResult
    func loadConfig(from path: String) -> Bool {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(StageManagerConfig.self, from: data)
            let spaces = Set(decoded.enabledSpaces.compactMap { UInt64($0) })
            setEnabledSpaces(spaces)
            print("[Config] Loaded \(spaces.count) spaces from \(path)")
            return true
        } catch {
            print("[Config] Failed to load configuration at \(path): \(error)")
            return false
        }
    }

    func addObserver(_ handler: @escaping (ConfigurationChange) -> Void) -> UUID {
        let token = UUID()
        queue.sync {
            observers[token] = handler
        }
        // Send initial snapshot
        handler(ConfigurationChange(spaceId: nil, isEnabled: nil, enabledSpaces: snapshotEnabledSpaces()))
        return token
    }

    func removeObserver(_ token: UUID) {
        return queue.sync {
            observers.removeValue(forKey: token)
        }
    }

    func enabledSpacesSnapshot() -> Set<UInt64> {
        return snapshotEnabledSpaces()
    }

    func shouldEnableStageManager(for spaceId: UInt64) -> Bool {
        return queue.sync {
            enabledSpaces.contains(spaceId)
        }
    }

    @discardableResult
    func toggleSpace(_ spaceId: UInt64) -> Bool {
        var newState = false
        var snapshot: Set<UInt64> = []
        queue.sync {
            if enabledSpaces.contains(spaceId) {
                enabledSpaces.remove(spaceId)
                newState = false
            } else {
                enabledSpaces.insert(spaceId)
                newState = true
            }
            snapshot = enabledSpaces
        }
        notifyChange(spaceId: spaceId, isEnabled: newState, snapshot: snapshot)
        return newState
    }

    func setSpace(_ spaceId: UInt64, enabled: Bool) {
        var changed = false
        var snapshot: Set<UInt64> = []
        queue.sync {
            let contains = enabledSpaces.contains(spaceId)
            if enabled != contains {
                changed = true
                if enabled {
                    enabledSpaces.insert(spaceId)
                } else {
                    enabledSpaces.remove(spaceId)
                }
            }
            snapshot = enabledSpaces
        }
        if changed {
            notifyChange(spaceId: spaceId, isEnabled: enabled, snapshot: snapshot)
        }
    }

    func setEnabledSpaces(_ spaces: Set<UInt64>) {
        queue.sync {
            enabledSpaces = spaces
        }
        notifyChange(spaceId: nil, isEnabled: nil, snapshot: spaces)
    }

    private func snapshotEnabledSpaces() -> Set<UInt64> {
        return queue.sync { enabledSpaces }
    }

    private func notifyChange(spaceId: UInt64?, isEnabled: Bool?, snapshot: Set<UInt64>) {
        let handlers: [((ConfigurationChange) -> Void)] = queue.sync { Array(observers.values) }
        let change = ConfigurationChange(spaceId: spaceId, isEnabled: isEnabled, enabledSpaces: snapshot)
        for handler in handlers {
            handler(change)
        }
    }
}