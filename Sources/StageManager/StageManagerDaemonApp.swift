import Foundation
import AppKit

class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private let configuration = Configuration()
    private var service: StageManagerService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Daemon] Stage Manager daemon started")

        let arguments = CommandLine.arguments
        if let configIndex = arguments.firstIndex(of: "--config"), configIndex + 1 < arguments.count {
            let path = arguments[configIndex + 1]
            configuration.loadConfig(from: path)
        } else if let bundledConfig = Bundle.main.path(forResource: "config", ofType: "json") {
            configuration.loadConfig(from: bundledConfig)
        }

        let service = StageManagerService(configuration: configuration)
        service.start()
        self.service = service

        print("[Daemon] Daemon is running, press Ctrl+C to exit")
    }

    func applicationWillTerminate(_ notification: Notification) {
        service?.stop()
    }
}