import Foundation
import AppKit
import CoreGraphics
import Darwin

typealias CGSConnectionID = UInt32
#if arch(arm64)
typealias CGSSpaceID = UInt64
#else
typealias CGSSpaceID = UInt32
#endif

class SpaceDetector {
    // 存储已知的桌面空间特征
    private static var knownSpaces: [String: UInt64] = [:]
    private static var nextSpaceID: UInt64 = 1
    private static var lastSpaceSignature: String = ""
    private static var lastSkyLightSpaceID: UInt64?
    private static var cachedSpaceLayout: ManagedSpaceLayout?
    private static var layoutCacheTimestamp: Date?
    private static var lastLayoutSignature: String?
    private static var lastSkyLightLogTime: Date = .distantPast

    private static let skyLightHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
        if handle == nil {
            let message = dlerror().map { String(cString: $0) } ?? "unknown error"
            print("[Space] Warning: Unable to load SkyLight framework: \(message)")
        }
        return handle
    }()

    private static let mainConnectionID: CGSConnectionID? = {
        guard let handle = skyLightHandle,
              let symbol = dlsym(handle, "CGSMainConnectionID") else {
            return nil
        }
        typealias ConnFn = @convention(c) () -> CGSConnectionID
        return unsafeBitCast(symbol, to: ConnFn.self)()
    }()

    private struct ManagedSpaceLayout {
        let orderedSpaceIDs: [UInt64]
        let idToUUID: [UInt64: String]
        let idToOrder: [UInt64: Int]
    }

    private typealias CGSGetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID

    private static let getActiveSpaceFunction: CGSGetActiveSpaceFn? = {
        guard let handle = skyLightHandle,
              let symbol = dlsym(handle, "CGSGetActiveSpace") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CGSGetActiveSpaceFn.self)
    }()

    // 使用智能桌面检测方法
    static func getCurrentSpaceID() -> UInt64? {
        if let skyLightID = getSkyLightSpaceID() {
            lastSkyLightSpaceID = skyLightID
            return skyLightID
        }

        let spaceSignature = generateDesktopSignature()
        
        // 如果签名没有变化，返回上次的结果
        if spaceSignature == lastSpaceSignature, let existingID = knownSpaces[spaceSignature] {
            return existingID
        }
        
        // 检查是否是已知的桌面空间
        if let existingID = knownSpaces[spaceSignature] {
            lastSpaceSignature = spaceSignature
            return existingID
        }
        
        // 这是一个新的桌面空间
        let newSpaceID = nextSpaceID
        knownSpaces[spaceSignature] = newSpaceID
        nextSpaceID += 1
        lastSpaceSignature = spaceSignature
        if Date().timeIntervalSince(lastSkyLightLogTime) > 1.0 {
            print("[Space] Tracking heuristically: \(describe(spaceID: newSpaceID, fallbackNumber: nil))")
            lastSkyLightLogTime = Date()
        }
        return newSpaceID
    }

    private static func getSkyLightSpaceID() -> UInt64? {
        guard let connection = mainConnectionID,
              let activeFn = getActiveSpaceFunction else {
            return nil
        }

        let space = activeFn(connection)
        if space == 0 {
            return nil
        }

        return UInt64(space)
    }

    static func getOrderedSpaceIDs(forceReload: Bool = false) -> [UInt64]? {
        return ensureSpaceLayout(forceReload: forceReload)?.orderedSpaceIDs
    }

    static func getSpaceNumber(for spaceID: UInt64) -> Int? {
        if let layout = ensureSpaceLayout(forceReload: false), let number = layout.idToOrder[spaceID] {
            return number
        }
        if let layout = ensureSpaceLayout(forceReload: true), let number = layout.idToOrder[spaceID] {
            return number
        }
        return nil
    }

    static func getSpaceID(for order: Int) -> UInt64? {
        guard order > 0 else { return nil }
        if let layout = ensureSpaceLayout(forceReload: false), let id = spaceID(from: layout, order: order) {
            return id
        }
        if let layout = ensureSpaceLayout(forceReload: true), let id = spaceID(from: layout, order: order) {
            return id
        }
        return nil
    }

    static func getSpaceUUID(for spaceID: UInt64) -> String? {
        if let layout = ensureSpaceLayout(forceReload: false), let uuid = layout.idToUUID[spaceID] {
            return uuid
        }
        if let layout = ensureSpaceLayout(forceReload: true), let uuid = layout.idToUUID[spaceID] {
            return uuid
        }
        return nil
    }

    static func describe(spaceID: UInt64, fallbackNumber: Int?) -> String {
        let number = getSpaceNumber(for: spaceID) ?? fallbackNumber
        let numberText = number.map { "#\($0)" } ?? "#?"

        if spaceID == 0 {
            return "\(numberText) [id 0]"
        }

        if let uuid = getSpaceUUID(for: spaceID) {
            let shortUUID = uuid.split(separator: "-").first.map(String.init) ?? String(uuid.prefix(8))
            return "\(numberText) [id \(spaceID)] (uuid \(shortUUID))"
        }
        return "\(numberText) [id \(spaceID)]"
    }

    private static func ensureSpaceLayout(forceReload: Bool) -> ManagedSpaceLayout? {
        let now = Date()
        if !forceReload,
           let cached = cachedSpaceLayout,
           let timestamp = layoutCacheTimestamp,
           now.timeIntervalSince(timestamp) < 1.0 {
            return cached
        }

        guard let layout = loadSpaceLayout() else {
            return cachedSpaceLayout
        }

        let signature = layout.orderedSpaceIDs.map(String.init).joined(separator: ",")
        if let lastSignature = lastLayoutSignature, lastSignature != signature {
            print("[Space] Space order changed -> \(formatSpaceSummary(for: layout))")
        }

        cachedSpaceLayout = layout
        layoutCacheTimestamp = now
        lastLayoutSignature = signature
        return layout
    }

    private static func loadSpaceLayout() -> ManagedSpaceLayout? {
        let prefsPath = NSHomeDirectory() + "/Library/Preferences/com.apple.spaces.plist"

        guard let plistData = NSDictionary(contentsOfFile: prefsPath) as? [String: Any],
              let displayConfig = plistData["SpacesDisplayConfiguration"] as? [String: Any],
              let managementData = displayConfig["Management Data"] as? [String: Any],
              let monitors = managementData["Monitors"] as? [[String: Any]] else {
            return nil
        }

        var orderedIDs: [UInt64] = []
        var idToUUID: [UInt64: String] = [:]

        for monitor in monitors {
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else {
                continue
            }

            for space in spaces {
                guard let managedIDValue = (space["ManagedSpaceID"] as? NSNumber) ?? (space["id64"] as? NSNumber),
                      let uuid = space["uuid"] as? String else {
                    continue
                }

                let spaceID = managedIDValue.uint64Value
                orderedIDs.append(spaceID)
                idToUUID[spaceID] = uuid
            }
        }

        guard !orderedIDs.isEmpty else {
            return nil
        }

        var idToOrder: [UInt64: Int] = [:]
        for (index, spaceID) in orderedIDs.enumerated() {
            idToOrder[spaceID] = index + 1
        }

        return ManagedSpaceLayout(orderedSpaceIDs: orderedIDs, idToUUID: idToUUID, idToOrder: idToOrder)
    }

    private static func formatSpaceSummary(for layout: ManagedSpaceLayout) -> String {
        return layout.orderedSpaceIDs.compactMap { id -> String? in
            guard let order = layout.idToOrder[id] else { return nil }
            let uuidPart = layout.idToUUID[id]?.prefix(8) ?? "-"
            return "#\(order)=\(uuidPart)"
        }.joined(separator: ", ")
    }

    private static func spaceID(from layout: ManagedSpaceLayout, order: Int) -> UInt64? {
        guard order > 0, order <= layout.orderedSpaceIDs.count else {
            return nil
        }
        return layout.orderedSpaceIDs[order - 1]
    }
    // 生成桌面特征签名 - 基于多种因素的组合
    private static func generateDesktopSignature() -> String {
        var components: [String] = []
        
        // 1. 前台应用程序
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            components.append("front:\(frontApp.bundleIdentifier ?? frontApp.localizedName ?? "unknown")")
        }
        
        // 2. 可见窗口的应用程序集合（按固定顺序）
        let visibleApps = getVisibleApplications()
        if !visibleApps.isEmpty {
            components.append("apps:\(visibleApps.sorted().joined(separator:","))")
        }
        
        // 3. 主要窗口的位置信息（粗略位置，忽略细微变化）
        let windowPositions = getMainWindowPositions()
        if !windowPositions.isEmpty {
            components.append("pos:\(windowPositions)")
        }
        
        // 4. 菜单栏应用程序状态
        let menubarState = getMenubarState()
        if !menubarState.isEmpty {
            components.append("menu:\(menubarState)")
        }
        
        return components.joined(separator:"|")
    }
    
    // 获取可见应用程序列表
    private static func getVisibleApplications() -> [String] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyHashable]] else {
            return []
        }
        
        var visibleApps = Set<String>()
        for window in windowList {
            guard let ownerName = window["kCGWindowOwnerName"] as? String,
                  let layer = window["kCGWindowLayer"] as? Int,
                  layer == 0 else { // 只考虑正常窗口层级
                continue
            }
            
            // 过滤掉系统级应用程序
            let systemApps = ["WindowServer", "Dock", "SystemUIServer", "loginwindow"]
            if !systemApps.contains(ownerName) {
                visibleApps.insert(ownerName)
            }
        }
        
        return Array(visibleApps)
    }
    
    // 获取主要窗口的大致位置信息
    private static func getMainWindowPositions() -> String {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyHashable]] else {
            return ""
        }
        
        var positions: [String] = []
        
        // 只考虑前几个最大的窗口
        let sortedWindows = windowList.compactMap { window -> (String, CGRect, Double)? in
            guard let ownerName = window["kCGWindowOwnerName"] as? String,
                  let layer = window["kCGWindowLayer"] as? Int,
                  layer == 0,
                  let bounds = window["kCGWindowBounds"] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double else {
                return nil
            }
            
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let area = width * height
            return (ownerName, rect, area)
        }.sorted { $0.2 > $1.2 } // 按面积排序
        
        // 只取前3个最大的窗口
        for (app, rect, _) in sortedWindows.prefix(3) {
            // 将位置四舍五入到最近的200像素，减少噪音
            let roundedX = Int(rect.origin.x / 200) * 200
            let roundedY = Int(rect.origin.y / 200) * 200
            positions.append("\(app)@\(roundedX),\(roundedY)")
        }
        
        return positions.joined(separator:",")
    }
    
    // 获取菜单栏状态（简化版）
    private static func getMenubarState() -> String {
        // 获取活跃应用程序的数量作为简单的菜单栏状态指示器
        let runningApps = NSWorkspace.shared.runningApplications.filter { 
            $0.activationPolicy == .regular && !$0.isHidden 
        }
        
        return "apps:\(runningApps.count)"
    }
}