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

    func loadConfig(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(StageManagerConfig.self, from: data)
            let spaces = Set(decoded.enabledSpaces.compactMap { UInt64($0) })
            setEnabledSpaces(spaces)
            print("[Config] Loaded \(spaces.count) spaces from \(url.path)")
            return true
        } catch {
            print("[Config] Failed to load configuration from \(url.path): \(error)")
            return false
        }
    }

    func addObserver(_ handler: @escaping (ConfigurationChange) -> Void) -> UUID {
        let token = UUID()
        let initialSnapshot = queue.sync { enabledSpaces }

        queue.sync {
            observers[token] = handler
        }

        // Send initial snapshot
        handler(ConfigurationChange(spaceId: nil, isEnabled: nil, enabledSpaces: initialSnapshot))
        return token
    }

    func removeObserver(_ token: UUID) {
        return queue.sync {
            observers.removeValue(forKey: token)
        }
    }

    func enabledSpacesSnapshot() -> Set<UInt64> {
        return queue.sync { enabledSpaces }
    }

    func shouldEnableStageManager(for spaceId: UInt64) -> Bool {
        return queue.sync {
            enabledSpaces.contains(spaceId)
        }
    }

    @discardableResult
    func toggleSpace(_ spaceId: UInt64) -> Bool {
        var newState = false
        var shouldNotify = false

        queue.sync {
            let wasEnabled = enabledSpaces.contains(spaceId)
            newState = !wasEnabled

            if newState {
                enabledSpaces.insert(spaceId)
            } else {
                enabledSpaces.remove(spaceId)
            }

            shouldNotify = true
        }

        if shouldNotify {
            let snapshot = queue.sync { enabledSpaces }
            notifyChange(spaceId: spaceId, isEnabled: newState, snapshot: snapshot)
        }

        return newState
    }

    func setSpace(_ spaceId: UInt64, enabled: Bool) {
        var shouldNotify = false

        queue.sync {
            let currentlyEnabled = enabledSpaces.contains(spaceId)
            if enabled != currentlyEnabled {
                if enabled {
                    enabledSpaces.insert(spaceId)
                } else {
                    enabledSpaces.remove(spaceId)
                }
                shouldNotify = true
            }
        }

        if shouldNotify {
            let snapshot = queue.sync { enabledSpaces }
            notifyChange(spaceId: spaceId, isEnabled: enabled, snapshot: snapshot)
        }
    }

    func setEnabledSpaces(_ spaces: Set<UInt64>) {
        queue.sync {
            guard enabledSpaces != spaces else { return }
            enabledSpaces = spaces
        }
        notifyChange(spaceId: nil, isEnabled: nil, snapshot: spaces)
    }

    func removeSpaces(_ spaceIds: Set<UInt64>) {
        var removedSpaces: Set<UInt64> = []
        var shouldNotify = false

        queue.sync {
            for spaceId in spaceIds {
                if enabledSpaces.remove(spaceId) != nil {
                    removedSpaces.insert(spaceId)
                }
            }
            shouldNotify = !removedSpaces.isEmpty
        }

        if shouldNotify {
            let snapshot = queue.sync { enabledSpaces }
            print("[Config] Removed \(removedSpaces.count) deleted spaces from enabled list: \(removedSpaces.map(String.init).sorted().joined(separator: ", "))")
            notifyChange(spaceId: nil, isEnabled: nil, snapshot: snapshot)
        }
    }

    // Removed snapshotEnabledSpaces() - use queue.sync { enabledSpaces } directly

    private func notifyChange(spaceId: UInt64?, isEnabled: Bool?, snapshot: Set<UInt64>) {
        let handlers: [((ConfigurationChange) -> Void)] = queue.sync { Array(observers.values) }
        let change = ConfigurationChange(spaceId: spaceId, isEnabled: isEnabled, enabledSpaces: snapshot)

        // Use async dispatch to avoid potential deadlocks
        DispatchQueue.global(qos: .userInitiated).async {
            for handler in handlers {
                handler(change)
            }
        }
    }
}