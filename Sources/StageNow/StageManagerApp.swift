import Foundation
import AppKit

class StageNowApp {
    private let stageManagerControl = StageManagerControl()
    private let configuration = Configuration()
    private var service: StageManagerService?
    private var configPath: String?

    func run() -> Int32 {
        let arguments = CommandLine.arguments

        // Load configuration first
        if let configIndex = arguments.firstIndex(of: "--config") {
            if configIndex + 1 < arguments.count {
                let configPath = arguments[configIndex + 1]
                configuration.loadConfig(from: configPath)
                self.configPath = configPath
            } else {
                print("Error: --config requires a file path")
                return 1
            }
        }

        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return 0
        }

        if arguments.contains("--install-agent") {
            return installAgent()
        }

        if arguments.contains("--uninstall-agent") {
            return uninstallAgent()
        }

        if arguments.contains("--reinstall-agent") {
            let uninstallResult = uninstallAgent()
            if uninstallResult != 0 {
                return uninstallResult
            }
            return installAgent()
        }

        if arguments.contains("--daemon") {
            startService()
            RunLoop.main.run()
            return 0
        }

        if arguments.contains("--toggle-globally") {
            stageManagerControl.toggleStageManager()
            return 0
        }

        if arguments.contains("--status") {
            printStatus()
            return 0
        }

        if arguments.contains("--enable") {
            stageManagerControl.enableStageManager()
            return 0
        }

        if arguments.contains("--disable") {
            stageManagerControl.disableStageManager()
            return 0
        }

        if let index = arguments.firstIndex(of: "--space-toggle"), index + 1 < arguments.count {
            let token = arguments[index + 1]
            guard let spaceId = resolveSpaceIdentifier(token) else {
                print("Error: --space-toggle requires a valid space identifier (order or id)")
                return 1
            }
            return performSpaceCommand(.toggle(spaceId))
        }

        if let index = arguments.firstIndex(of: "--space-enable"), index + 1 < arguments.count {
            let token = arguments[index + 1]
            guard let spaceId = resolveSpaceIdentifier(token) else {
                print("Error: --space-enable requires a valid space identifier (order or id)")
                return 1
            }
            return performSpaceCommand(.set(spaceId, true))
        }

        if let index = arguments.firstIndex(of: "--space-disable"), index + 1 < arguments.count {
            let token = arguments[index + 1]
            guard let spaceId = resolveSpaceIdentifier(token) else {
                print("Error: --space-disable requires a valid space identifier (order or id)")
                return 1
            }
            return performSpaceCommand(.set(spaceId, false))
        }

        if arguments.contains("--toggle") {
            if let currentSpaceId = SpaceDetector.getCurrentSpaceID() {
                return performSpaceCommand(.toggle(currentSpaceId))
            } else {
                print("Error: Unable to determine current space ID")
                return 1
            }
        }

        if arguments.contains("--snapshot") {
            return performSpaceCommand(.status)
        }

        printUsage()
        return 0
    }

    private func startService() {
        print("[App] Starting Stage Manager service...")
        let service = StageManagerService(configuration: configuration)
        service.start()
        self.service = service
    }

    private func printStatus() {
        let isEnabled = stageManagerControl.isStageManagerEnabled()
        print("Stage Manager is: \(isEnabled ? "Enabled" : "Disabled")")

        if performSpaceCommand(.status) != 0 {
            let spaces = configuration.enabledSpacesSnapshot().map(String.init).sorted()
            print("Configuration (local snapshot): \(spaces)")
        }
    }

    private func printUsage() {
        print("""
        Stage Manager Controller

        USAGE:
          StageNow [OPTIONS]

        OPTIONS:
          --daemon              Run in background to monitor space changes

          --enable              Enable Stage Manager
          --disable             Disable Stage Manager
          --status              Show current status
          --snapshot            Print spaces tracked by the daemon in JSON format
          --toggle-globally     Toggle Stage Manager on/off

          --toggle              Toggle Stage Manager for the current space
          --space-toggle <id>   Toggle Stage Manager for a specific space
          --space-enable <id>   Enable Stage Manager for the given space
          --space-disable <id>  Disable Stage Manager for the given space

          --install-agent       Install and start the StageNow launch agent (persists daemon)
          --reinstall-agent     Reinstall the StageNow launch agent
          --uninstall-agent     Stop and remove the StageNow launch agent
          --help, -h            Show help information

        RUNTIME CONTROL:
          When the daemon is running, the CLI communicates via XPC.
          Start the daemon first:
            StageNow --daemon
          Or install the launch agent to run it automatically:
            StageNow --install-agent
          Then run commands such as:
            StageNow --toggle
            StageNow --snapshot
        """)
    }

    private enum SpaceCommand {
        case toggle(UInt64)
        case set(UInt64, Bool)
        case status
    }

    private func performSpaceCommand(_ command: SpaceCommand) -> Int32 {
        do {
            let client = try StageManagerXPCClient()
            defer { client.invalidate() }

            switch command {
            case .toggle(let spaceId):
                let enabled = try client.toggleSpace(spaceId)
                let description = describeSpace(spaceId)
                let stateText = enabled ? "enabled" : "disabled"
                print("Space \(description) -> \(stateText)")
                return 0
            case .set(let spaceId, let enabled):
                _ = try client.setSpace(spaceId, enabled: enabled)
                let description = describeSpace(spaceId)
                let stateText = enabled ? "enabled" : "disabled"
                print("Space \(description) set to \(stateText)")
                return 0
            case .status:
                let snapshot = try client.status()

                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let jsonData = try encoder.encode(snapshot)
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        print(jsonString)
                    } else {
                        print("Space status: current=\(snapshot.current), spaces=\(snapshot.spaces)")
                    }
                } catch {
                    print("Space status: current=\(snapshot.current), spaces=\(snapshot.spaces)")
                }
                return 0
            }
        } catch let error as StageManagerXPCClient.ClientError {
            switch error {
            case .daemonUnavailable:
                print("StageNow daemon is not available. Start it with 'StageNow --daemon' or install it via '--install-agent'.")
            case .timeout:
                print("StageManager daemon did not respond in time.")
            case .invalidEndpoint:
                print("Failed to contact StageManager daemon: invalid endpoint information.")
            case .connectionFailed(let underlying):
                if let underlying {
                    print("Failed to communicate with daemon: \(underlying.localizedDescription)")
                } else {
                    print("Failed to communicate with daemon.")
                }
            case .invalidResponse:
                print("StageManager daemon returned an invalid response.")
            }
            return 1
        } catch {
            print("Unexpected error communicating with StageManager daemon: \(error)")
            return 1
        }
    }

    private func installAgent() -> Int32 {
        do {
            let manager = LaunchAgentManager()
            try manager.install(configPath: configPath)
            print("StageNow launch agent installed at \(LaunchAgentManager.agentPlistURL.path)")
            return 0
        } catch let error as LaunchAgentManager.AgentError {
            print(error.description)
            return 1
        } catch {
            print("Unexpected error installing launch agent: \(error)")
            return 1
        }
    }

    private func uninstallAgent() -> Int32 {
        do {
            let manager = LaunchAgentManager()
            try manager.uninstall()
            print("StageNow launch agent uninstalled")
            return 0
        } catch let error as LaunchAgentManager.AgentError {
            print(error.description)
            return 1
        } catch {
            print("Unexpected error uninstalling launch agent: \(error)")
            return 1
        }
    }

    private func resolveSpaceIdentifier(_ rawValue: String) -> UInt64? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("order:") || lowercased.hasPrefix("order=") {
            if let separatorIndex = trimmed.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let orderString = trimmed[trimmed.index(after: separatorIndex)...]
                if let order = Int(orderString) {
                    if let spaceId = SpaceDetector.getSpaceID(for: order) {
                        return spaceId
                    }
                }
            }
        }

        if let order = Int(trimmed), let spaceId = SpaceDetector.getSpaceID(for: order) {
            return spaceId
        }

        if let spaceId = UInt64(trimmed) {
            return spaceId
        }

        return nil
    }

    private func describeSpace(_ spaceId: UInt64) -> String {
        let number = SpaceDetector.getSpaceNumber(for: spaceId)
        return SpaceDetector.describe(spaceID: spaceId, fallbackNumber: number)
    }
}