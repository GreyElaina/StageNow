import Foundation
import Darwin

final class StageManagerXPCClient {
    enum ClientError: Error {
        case daemonUnavailable
        case invalidEndpoint
        case connectionFailed(Error?)
        case invalidResponse
        case timeout
    }

    private let connection: NSXPCConnection
    private let pidURL: URL

    init() throws {
        pidURL = StageManagerService.pidFileURL()
        let info = try StageManagerXPCClient.loadEndpointInfo(at: pidURL)
        guard StageManagerXPCClient.isProcessRunning(pid: info.pid) else {
            try? FileManager.default.removeItem(at: pidURL)
            throw ClientError.daemonUnavailable
        }

        let connection = NSXPCConnection(machServiceName: StageManagerService.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: StageManagerXPCProtocol.self)
        connection.resume()
        self.connection = connection
    }

    deinit {
        connection.invalidate()
    }

    func invalidate() {
        connection.invalidate()
    }

    func toggleSpace(_ spaceId: UInt64) throws -> Bool {
        try request { proxy, reply in
            proxy.toggleSpace(spaceId, withReply: reply)
        }
    }

    func setSpace(_ spaceId: UInt64, enabled: Bool) throws -> Bool {
        try request { proxy, reply in
            proxy.setSpace(spaceId, enabled: enabled, withReply: reply)
        }
    }

    func status() throws -> SpaceStatusSnapshot {
        let raw: [String: NSObject] = try request { proxy, reply in
            proxy.status(withReply: reply)
        }

        guard let snapshot = SpaceStatusSnapshot.fromPropertyList(raw) else {
            throw ClientError.invalidResponse
        }

        return snapshot
    }

    // MARK: - Private helpers

    private func request<T>(
        _ sender: (StageManagerXPCProtocol, @escaping (T) -> Void) -> Void
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        var remoteError: Error?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            remoteError = error
            semaphore.signal()
        }) as? StageManagerXPCProtocol else {
            throw ClientError.invalidEndpoint
        }

        sender(proxy) { value in
            result = value
            semaphore.signal()
        }

        let timeoutResult = semaphore.wait(timeout: .now() + 5)
        if timeoutResult == .timedOut {
            throw ClientError.timeout
        }

        if let error = remoteError {
            throw ClientError.connectionFailed(error)
        }

        guard let unwrappedResult = result else {
            throw ClientError.invalidResponse
        }

        return unwrappedResult
    }

    private static func loadEndpointInfo(at url: URL) throws -> StageManagerEndpointInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClientError.daemonUnavailable
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(StageManagerEndpointInfo.self, from: data)
        } catch _ as DecodingError {
            try? FileManager.default.removeItem(at: url)
            throw ClientError.daemonUnavailable
        } catch {
            throw ClientError.connectionFailed(error)
        }
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH ? true : false
    }
}
