import Foundation
import AppKit

enum AppMode {
    case daemon
    case commandLine
}

func getAppMode() -> AppMode {
    return CommandLine.arguments.contains("--daemon") ? .daemon : .commandLine
}

func runDaemonMode() -> Never {
    let daemonApp = NSApplication.shared
    daemonApp.setActivationPolicy(.accessory)
    let appDelegate = DaemonAppDelegate()
    daemonApp.delegate = appDelegate
    daemonApp.run()
    fatalError("runDaemonMode() should never return")
}

func runCommandLineMode() -> Int32 {
    let app = StageManagerApp()
    return app.run()
}

switch getAppMode() {
case .daemon:
    runDaemonMode()
case .commandLine:
    exit(runCommandLineMode())
}