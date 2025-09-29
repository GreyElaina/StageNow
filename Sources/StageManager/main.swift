import Foundation
import AppKit

// Check if we're running in daemon mode
if CommandLine.arguments.contains("--daemon") {
    // Run as proper app for daemon mode
    let daemonApp = NSApplication.shared
    daemonApp.setActivationPolicy(.accessory)
    let appDelegate = DaemonAppDelegate()
    daemonApp.delegate = appDelegate
    daemonApp.run()
} else {
    // Run as command line tool for other modes
    let app = StageManagerApp()
    let exitCode = app.run()
    exit(exitCode)
}