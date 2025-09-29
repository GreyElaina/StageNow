import Foundation
import AppKit

class StageManagerControl {
    private let stageManagerDomain = "com.apple.WindowManager"
    private let stageManagerKey = "GloballyEnabled"

    func enableStageManager() {
        _ = executeCommand("defaults write \(stageManagerDomain) \(stageManagerKey) -bool true")
    }

    func disableStageManager() {
        _ = executeCommand("defaults write \(stageManagerDomain) \(stageManagerKey) -bool false")
    }

    func toggleStageManager() {
        if isStageManagerEnabled() {
            disableStageManager()
        } else {
            enableStageManager()
        }
    }

    func isStageManagerEnabled() -> Bool {
        let output = executeCommand("defaults read \(stageManagerDomain) \(stageManagerKey)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func executeCommand(_ command: String) -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.arguments = ["-c", command]
        process.executableURL = URL(fileURLWithPath: "/bin/bash")

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if !errorData.isEmpty, let errorMessage = String(data: errorData, encoding: .utf8) {
                print("Command error: \(errorMessage)")
            }

            return String(data: outputData, encoding: .utf8) ?? ""
        } catch {
            print("Error executing command: \(error)")
            return ""
        }
    }
}