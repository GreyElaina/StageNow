import Foundation

@objc(StageManagerXPCProtocol)
protocol StageManagerXPCProtocol {
    func toggleSpace(_ spaceId: UInt64, withReply reply: @escaping (Bool) -> Void)
    func setSpace(_ spaceId: UInt64, enabled: Bool, withReply reply: @escaping (Bool) -> Void)
    func status(withReply reply: @escaping ([String: NSObject]) -> Void)
}
