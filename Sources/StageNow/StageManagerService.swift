import Foundation
import AppKit

final class StageManagerService: NSObject, NSXPCListenerDelegate {
    private let spaceMonitor = SpaceMonitor()
    private let stageManagerControl = StageManagerControl()
    private let configuration: Configuration
    private let listener: NSXPCListener
    private let pidURL: URL
    private let connections = NSHashTable<NSXPCConnection>.weakObjects()
    private var configObserverToken: UUID?
    private var knownSpaceIDs = Set<UInt64>()

    private let stateQueue = DispatchQueue(label: "by.akashina.stagenow.service")
    private var currentSpaceID: UInt64 = 0
    private var currentSpaceNumber: Int = 0
    private var lastAppliedSpaceID: UInt64 = 0
    private var lastAppliedState: Bool?

    static let machServiceName = "by.akashina.stagenow"

    init(configuration: Configuration) {
        self.configuration = configuration
        self.listener = NSXPCListener(machServiceName: StageManagerService.machServiceName)
        self.pidURL = StageManagerService.pidFileURL()
        super.init()
    }

    func start() {
        listener.delegate = self
        listener.resume()
        writeEndpointInfo()

        print("[XPC] Mach service '\(StageManagerService.machServiceName)' ready (PID: \(ProcessInfo.processInfo.processIdentifier))")

        configObserverToken = configuration.addObserver { [weak self] change in
            self?.handleConfigurationChange(change)
        }

        spaceMonitor.onSpaceChange = { [weak self] spaceId, spaceNumber in
            self?.handleSpaceChange(spaceId: spaceId, spaceNumber: spaceNumber)
        }
        spaceMonitor.onSpacesRemoved = { [weak self] removedSpaceIds in
            self?.handleSpacesRemoved(removedSpaceIds: removedSpaceIds)
        }
        spaceMonitor.startMonitoring()

        stateQueue.async { [weak self] in
            guard let self else { return }
            if let orderedSpaces = SpaceDetector.getOrderedSpaceIDs(forceReload: true) {
                self.knownSpaceIDs.formUnion(orderedSpaces)
            }
            self.knownSpaceIDs.formUnion(self.configuration.enabledSpacesSnapshot())
            if self.currentSpaceID != 0 {
                self.knownSpaceIDs.insert(self.currentSpaceID)
            }
        }
    }

    func stop() {
        if let token = configObserverToken {
            configuration.removeObserver(token)
            configObserverToken = nil
        }
        spaceMonitor.stopMonitoring()
        listener.suspend()
        removeEndpointInfo()
    }

    private func handleSpaceChange(spaceId: UInt64, spaceNumber: Int) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.currentSpaceID = spaceId
            self.currentSpaceNumber = spaceNumber
            self.knownSpaceIDs.insert(spaceId)
            self.applyStageManagerState(for: spaceId, spaceNumber: spaceNumber)
        }
    }

    private func handleConfigurationChange(_ change: ConfigurationChange) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let spaceId = change.spaceId, let enabled = change.isEnabled {
                let description = SpaceDetector.describe(spaceID: spaceId, fallbackNumber: nil)
                print("[Config] Space \(description) -> \(enabled ? "enabled" : "disabled")")
            } else {
                let summary = change.enabledSpaces.map(String.init).sorted().joined(separator: ", ")
                print("[Config] Enabled spaces: [\(summary)]")
            }

            if self.currentSpaceID != 0 {
                self.applyStageManagerState(for: self.currentSpaceID, spaceNumber: self.currentSpaceNumber)
            }
        }
    }

    private func handleSpacesRemoved(removedSpaceIds: Set<UInt64>) {
        stateQueue.async { [weak self] in
            guard let self else { return }

            // Remove from known space IDs
            self.knownSpaceIDs.subtract(removedSpaceIds)

            // Clean up configuration
            self.configuration.removeSpaces(removedSpaceIds)

            print("[Service] Cleaned up \(removedSpaceIds.count) deleted spaces from internal state")
        }
    }

    private func applyStageManagerState(for spaceId: UInt64, spaceNumber: Int) {
        guard spaceId != 0 else { return }
        let shouldEnable = configuration.shouldEnableStageManager(for: spaceId)

        if lastAppliedSpaceID == spaceId, lastAppliedState == shouldEnable {
            return
        }

        lastAppliedSpaceID = spaceId
        lastAppliedState = shouldEnable

        let description = SpaceDetector.describe(spaceID: spaceId, fallbackNumber: spaceNumber)
        if shouldEnable {
            print("[Stage] Space \(description): Enabling Stage Manager")
            stageManagerControl.enableStageManager()
        } else {
            print("[Stage] Space \(description): Disabling Stage Manager")
            stageManagerControl.disableStageManager()
        }
    }

    // MARK: - XPC support

    static func pidFileURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("StageManager", isDirectory: true)
        return base.appendingPathComponent("daemon.pid")
    }

    private func writeEndpointInfo() {
        do {
            let directory = pidURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let info = StageManagerEndpointInfo(pid: Int32(ProcessInfo.processInfo.processIdentifier))
            let data = try JSONEncoder().encode(info)
            try data.write(to: pidURL, options: .atomic)
            print("[XPC] Endpoint info written to: \(pidURL.path)")
        } catch {
            print("[XPC] Failed to write endpoint info: \(error)")
        }
    }

    private func removeEndpointInfo() {
        do {
            if FileManager.default.fileExists(atPath: pidURL.path) {
                try FileManager.default.removeItem(at: pidURL)
            }
        } catch {
            print("[XPC] Failed to remove PID: \(error)")
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: StageManagerXPCProtocol.self)
        connection.exportedObject = StageManagerXPCHandler(service: self)
        connection.resume()
        connections.add(connection)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection, let self else { return }
            self.connections.remove(connection)
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection, let self else { return }
            self.connections.remove(connection)
        }
        return true
    }

    fileprivate func toggleSpace(_ spaceId: UInt64, completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            self.knownSpaceIDs.insert(spaceId)
            let result = self.configuration.toggleSpace(spaceId)

            let spaceNumber = SpaceDetector.getSpaceNumber(for: spaceId) ?? self.currentSpaceNumber
            self.applyStageManagerState(for: spaceId, spaceNumber: spaceNumber)

            completion(result)
        }
    }

    fileprivate func setSpace(_ spaceId: UInt64, enabled: Bool, completion: @escaping (Bool) -> Void) {
        stateQueue.async {
            self.knownSpaceIDs.insert(spaceId)
            self.configuration.setSpace(spaceId, enabled: enabled)

            let spaceNumber = SpaceDetector.getSpaceNumber(for: spaceId) ?? self.currentSpaceNumber
            self.applyStageManagerState(for: spaceId, spaceNumber: spaceNumber)

            completion(enabled)
        }
    }

    fileprivate func enabledSpaces(completion: @escaping ([UInt64]) -> Void) {
        stateQueue.async {
            let spaces = Array(self.configuration.enabledSpacesSnapshot())
            completion(spaces)
        }
    }

    fileprivate func spaceStatus(completion: @escaping ([String: NSObject]) -> Void) {
        stateQueue.async {
            let detectedSpaceID: UInt64?
            if Thread.isMainThread {
                detectedSpaceID = SpaceDetector.getCurrentSpaceID()
            } else {
                detectedSpaceID = DispatchQueue.main.sync {
                    SpaceDetector.getCurrentSpaceID()
                }
            }

            if let detectedSpaceID, detectedSpaceID != 0 {
                self.currentSpaceID = detectedSpaceID
                if let detectedNumber = SpaceDetector.getSpaceNumber(for: detectedSpaceID) {
                    self.currentSpaceNumber = detectedNumber
                }
                self.knownSpaceIDs.insert(detectedSpaceID)
            }

            if let orderedIDs = SpaceDetector.getOrderedSpaceIDs(forceReload: true) {
                self.knownSpaceIDs.formUnion(orderedIDs)
            }

            var allSpaceIDs = self.knownSpaceIDs
            let enabledSpaces = self.configuration.enabledSpacesSnapshot()
            allSpaceIDs.formUnion(enabledSpaces)

            if self.currentSpaceID != 0 {
                allSpaceIDs.insert(self.currentSpaceID)
            }

            var entries: [SpaceStatusEntry] = []
            entries.reserveCapacity(allSpaceIDs.count)

            for spaceID in allSpaceIDs {
                let enabled = enabledSpaces.contains(spaceID)
                let order = SpaceDetector.getSpaceNumber(for: spaceID)
                let uuid = SpaceDetector.getSpaceUUID(for: spaceID)
                let description = SpaceDetector.describe(spaceID: spaceID, fallbackNumber: order)

                let entry = SpaceStatusEntry(
                    id: spaceID,
                    order: order,
                    uuid: uuid,
                    description: description,
                    enabled: enabled
                )

                entries.append(entry)
            }

            let sortedEntries = entries.sorted { lhs, rhs in
                switch (lhs.order, rhs.order) {
                case let (l?, r?) where l != r:
                    return l < r
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                default:
                    return lhs.id < rhs.id
                }
            }

            let currentSpaceEntry: SpaceStatusEntry?
            if self.currentSpaceID != 0 {
                if let existing = sortedEntries.first(where: { $0.id == self.currentSpaceID }) {
                    currentSpaceEntry = existing
                } else {
                    let currentEnabled = enabledSpaces.contains(self.currentSpaceID)
                    let currentOrder = SpaceDetector.getSpaceNumber(for: self.currentSpaceID)
                    let currentUUID = SpaceDetector.getSpaceUUID(for: self.currentSpaceID)
                    let description = SpaceDetector.describe(spaceID: self.currentSpaceID, fallbackNumber: currentOrder ?? self.currentSpaceNumber)
                    currentSpaceEntry = SpaceStatusEntry(
                        id: self.currentSpaceID,
                        order: currentOrder,
                        uuid: currentUUID,
                        description: description,
                        enabled: currentEnabled
                    )
                }
            } else {
                currentSpaceEntry = nil
            }

            let currentSpaceHint: Int?
            if let currentSpaceEntry {
                currentSpaceHint = currentSpaceEntry.order
            } else if self.currentSpaceID != 0 {
                currentSpaceHint = SpaceDetector.getSpaceNumber(for: self.currentSpaceID) ?? self.currentSpaceNumber
            } else {
                currentSpaceHint = nil
            }

            let currentStatus = CurrentSpaceStatus(
                enabled: self.stageManagerControl.isStageManagerEnabled(),
                hint: currentSpaceHint
            )

            let snapshot = SpaceStatusSnapshot(
                current: currentStatus,
                spaces: sortedEntries
            )

            completion(snapshot.toPropertyList())
        }
    }
}

private final class StageManagerXPCHandler: NSObject, StageManagerXPCProtocol {
    private weak var service: StageManagerService?

    init(service: StageManagerService) {
        self.service = service
    }

    func toggleSpace(_ spaceId: UInt64, withReply reply: @escaping (Bool) -> Void) {
        guard let service else {
            reply(false)
            return
        }
        service.toggleSpace(spaceId) { enabled in
            reply(enabled)
        }
    }

    func setSpace(_ spaceId: UInt64, enabled: Bool, withReply reply: @escaping (Bool) -> Void) {
        guard let service else {
            reply(false)
            return
        }
        service.setSpace(spaceId, enabled: enabled) { _ in
            reply(enabled)
        }
    }

    func status(withReply reply: @escaping ([String: NSObject]) -> Void) {
        guard let service else {
            reply([:])
            return
        }
        service.spaceStatus { status in
            reply(status)
        }
    }
}
