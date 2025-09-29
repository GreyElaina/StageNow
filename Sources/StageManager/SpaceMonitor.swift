import Foundation
import AppKit
import CoreGraphics

final class SpaceMonitor {
    var onSpaceChange: ((UInt64, Int) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var currentSpaceID: UInt64 = 0
    private var currentSpaceNumber: Int = 0
    private var changeCounter: UInt64 = 0

    private var spaceIDToSpaceNumber: [UInt64: Int] = [:]
    private var nextSpaceNumber: Int = 1
    private var lastSpaceOrderSignature: String?

    func startMonitoring() {
        print("[Listen] Starting space monitoring...")

        currentSpaceID = getCurrentSpaceID()
        syncSpaceMappingWithLayout()

        if currentSpaceID != 0 {
            currentSpaceNumber = getSpaceNumber(for: currentSpaceID)
            print("[Listen] Initial space: \(SpaceDetector.describe(spaceID: currentSpaceID, fallbackNumber: currentSpaceNumber))")
        } else {
            print("[Listen] Initial space unknown (space ID unavailable)")
        }

        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("[Listen] Space change notification received: \(notification.name)")
            self?.handleSpaceChange()
        }
        observers.append(spaceObserver)

        let appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("[Listen] App activation notification: \(notification.userInfo?[NSWorkspace.applicationUserInfoKey] ?? "unknown")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.handleSpaceChange()
            }
        }
        observers.append(appObserver)

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.handleSpaceChange()
        }

        print("[Listen] Space monitoring started successfully with multiple methods")
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()

        print("[Listen] Space monitoring stopped")
    }

    private func handleSpaceChange() {
        syncSpaceMappingWithLayout()

        let newSpaceID = getCurrentSpaceID()
        let newSpaceNumber = getSpaceNumber(for: newSpaceID)

        if newSpaceID != currentSpaceID && newSpaceID != 0 {
            changeCounter += 1
            let oldSpaceID = currentSpaceID
            let oldSpaceNumber = currentSpaceNumber
            currentSpaceID = newSpaceID
            currentSpaceNumber = newSpaceNumber

            print("[Listen] Space change #\(changeCounter): \(SpaceDetector.describe(spaceID: oldSpaceID, fallbackNumber: oldSpaceNumber)) -> \(SpaceDetector.describe(spaceID: newSpaceID, fallbackNumber: newSpaceNumber))")
            onSpaceChange?(currentSpaceID, newSpaceNumber)
        } else if newSpaceID == 0 {
            print("[Listen] Warning: Unable to get valid space ID")
        } else if newSpaceNumber != currentSpaceNumber {
            let previousNumber = currentSpaceNumber
            currentSpaceNumber = newSpaceNumber
            print("[Listen] Space renumbered: \(SpaceDetector.describe(spaceID: newSpaceID, fallbackNumber: previousNumber)) -> \(SpaceDetector.describe(spaceID: newSpaceID, fallbackNumber: newSpaceNumber))")
            onSpaceChange?(currentSpaceID, newSpaceNumber)
        }
    }

    private func getSpaceNumber(for spaceID: UInt64) -> Int {
        if spaceID == 0 {
            return 0
        }

        if let number = SpaceDetector.getSpaceNumber(for: spaceID) {
            spaceIDToSpaceNumber[spaceID] = number
            nextSpaceNumber = max(nextSpaceNumber, number + 1)
            return number
        }

        if let existingNumber = spaceIDToSpaceNumber[spaceID] {
            return existingNumber
        }

        let spaceNumber = nextSpaceNumber
        spaceIDToSpaceNumber[spaceID] = spaceNumber
        nextSpaceNumber += 1

        print("[Listen] New space discovered: Space \(spaceNumber) (ID: \(spaceID))")

        return spaceNumber
    }

    private func syncSpaceMappingWithLayout() {
        guard let orderedSpaceIDs = SpaceDetector.getOrderedSpaceIDs() else {
            return
        }

        var updatedMapping: [UInt64: Int] = [:]
        for (index, id) in orderedSpaceIDs.enumerated() {
            updatedMapping[id] = index + 1
        }

        for (id, number) in spaceIDToSpaceNumber where updatedMapping[id] == nil {
            updatedMapping[id] = number
        }

        spaceIDToSpaceNumber = updatedMapping
        nextSpaceNumber = (spaceIDToSpaceNumber.values.max() ?? 0) + 1

        let signature = orderedSpaceIDs.map(String.init).joined(separator: ",")
        if signature != lastSpaceOrderSignature {
            let summary = orderedSpaceIDs.compactMap { id -> String? in
                guard let number = spaceIDToSpaceNumber[id] else { return nil }
                let uuidPart = SpaceDetector.getSpaceUUID(for: id)?.prefix(8) ?? "-"
                return "#\(number)=\(uuidPart)"
            }.joined(separator: ", ")
            print("[Listen] Space order synced: \(summary)")
            lastSpaceOrderSignature = signature
        }
    }

    private func getCurrentSpaceID() -> UInt64 {
        if let spaceID = SpaceDetector.getCurrentSpaceID() {
            return spaceID
        }

        let windowHash = getWindowHash()
        if windowHash != 0 {
            return windowHash
        }

        let appHash = getApplicationHash()
        if appHash != 0 {
            return appHash
        }

        return getConsistentSpaceID()
    }

    private func getWindowHash() -> UInt64 {
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyHashable]] else {
            return 0
        }

        let visibleWindows = windowList.filter { window in
            guard let windowLayer = window["kCGWindowLayer"] as? Int else { return false }
            return windowLayer == 0
        }

        var hasher = Hasher()
        for window in visibleWindows {
            if let windowName = window["kCGWindowName"] as? String {
                hasher.combine(windowName)
            }
            if let ownerName = window["kCGWindowOwnerName"] as? String {
                hasher.combine(ownerName)
            }
            if let windowNumber = window["kCGWindowNumber"] as? UInt64 {
                hasher.combine(windowNumber)
            }
        }

        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func getApplicationHash() -> UInt64 {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications

        var hasher = Hasher()
        for app in runningApps where app.activationPolicy == .regular {
            hasher.combine(app.bundleIdentifier ?? "")
            hasher.combine(app.localizedName ?? "")
        }

        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func getConsistentSpaceID() -> UInt64 {
        let timestamp = Date().timeIntervalSince1970
        let processList = NSWorkspace.shared.runningApplications.map { $0.processIdentifier }

        var hasher = Hasher()
        hasher.combine(timestamp)
        for process in processList {
            hasher.combine(process)
        }

        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
