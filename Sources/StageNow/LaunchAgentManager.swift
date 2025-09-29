import Foundation
import Darwin

final class LaunchAgentManager {
    enum AgentError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case writeFailed(String)
        case launchctlFailed(String, Int32)
        case removalFailed(String)

        var description: String {
            switch self {
            case .binaryNotFound(let path):
                return "Could not locate StageNow binary at \(path). Build the project first."
            case .writeFailed(let message):
                return "Failed to write launch agent: \(message)"
            case .launchctlFailed(let message, let code):
                return "launchctl command failed (code \(code)): \(message)"
            case .removalFailed(let message):
                return "Failed to remove launch agent: \(message)"
            }
        }
    }

    private static let label = StageManagerService.machServiceName

    static var agentPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var logDirectoryURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("StageManager", isDirectory: true)
    }

    func install(configPath: String?) throws {
        let binaryPath = LaunchAgentManager.resolveBinaryPath()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw AgentError.binaryNotFound(binaryPath)
        }

        let programArguments = LaunchAgentManager.buildProgramArguments(binaryPath: binaryPath, configPath: configPath)
        let plistData = try LaunchAgentManager.serializedPlist(programArguments: programArguments)

        let plistURL = LaunchAgentManager.agentPlistURL
        let directory = plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plistData.write(to: plistURL, options: .atomic)
        } catch {
            throw AgentError.writeFailed(error.localizedDescription)
        }

        try LaunchAgentManager.ensureLogDirectory()

        // Stop any existing instance before bootstrapping
        try runLaunchctl(arguments: ["bootout", LaunchAgentManager.guiTargetWithLabel()], allowFailure: true)

        do {
            try runLaunchctl(arguments: ["bootstrap", LaunchAgentManager.guiTarget(), plistURL.path], allowFailure: false)
            try runLaunchctl(arguments: ["enable", LaunchAgentManager.guiTargetWithLabel()], allowFailure: false)
            print("Launch agent installed and started (label: \(LaunchAgentManager.label))")
        } catch let AgentError.launchctlFailed(message, code) {
            if code == 5 || message.contains("Bootstrap failed") {
                print("launchctl bootstrap failed (code \(code)). Falling back to legacy load command.")
                try installUsingLegacyLoad(plistURL: plistURL)
            } else {
                throw AgentError.launchctlFailed(message, code)
            }
        }
    }

    func uninstall() throws {
        let plistURL = LaunchAgentManager.agentPlistURL
        try runLaunchctl(arguments: ["bootout", LaunchAgentManager.guiTargetWithLabel()], allowFailure: true)
        try runLaunchctl(arguments: ["disable", LaunchAgentManager.guiTargetWithLabel()], allowFailure: true)
        try runLaunchctl(arguments: ["unload", "-w", plistURL.path], allowFailure: true)

        if FileManager.default.fileExists(atPath: plistURL.path) {
            do {
                try FileManager.default.removeItem(at: plistURL)
                print("Launch agent file removed at \(plistURL.path)")
            } catch {
                throw AgentError.removalFailed(error.localizedDescription)
            }
        } else {
            print("No launch agent file found at \(plistURL.path)")
        }
    }

    // MARK: - Helpers

    private static func resolveBinaryPath() -> String {
        let executablePath = CommandLine.arguments[0]
        return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
    }

    private static func buildProgramArguments(binaryPath: String, configPath: String?) -> [String] {
        var args = [binaryPath, "--daemon"]
        if let configPath, !configPath.isEmpty {
            args.append(contentsOf: ["--config", configPath])
        }
        return args
    }

    private static func serializedPlist(programArguments: [String]) throws -> Data {
        let stdoutPath = logDirectoryURL.appendingPathComponent("StageManager-daemon.log").path
        let stderrPath = logDirectoryURL.appendingPathComponent("StageManager-daemon.err.log").path

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "MachServices": [label: true],
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func ensureLogDirectory() throws {
        let logsDirectory = logDirectoryURL
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    private static func guiTarget() -> String {
        return "gui/\(getuid())"
    }

    private static func guiTargetWithLabel() -> String {
        return "\(guiTarget())/\(label)"
    }

    @discardableResult
    private func runLaunchctl(arguments: [String], allowFailure: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AgentError.launchctlFailed(error.localizedDescription, -1)
        }

        process.waitUntilExit()
        let status = process.terminationStatus

        if status != 0 && !allowFailure {
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = [stdoutData, stderrData]
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentError.launchctlFailed(message.isEmpty ? "Unknown error" : message, status)
        }

        return status
    }

    private func installUsingLegacyLoad(plistURL: URL) throws {
        try runLaunchctl(arguments: ["unload", "-w", plistURL.path], allowFailure: true)
        try runLaunchctl(arguments: ["load", "-w", plistURL.path], allowFailure: false)
        print("Launch agent installed using legacy 'launchctl load -w'.")
    }
}
