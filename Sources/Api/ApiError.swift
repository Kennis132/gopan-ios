import Foundation

/// 与桌面端 client.js 的 ApiError 对应：status 为 0 表示未到达 HTTP 层
/// （no_server / network），code 是服务端业务错误码（如 oversize、closed）。
public struct ApiError: Error, Equatable, Sendable {
    public let message: String
    public let status: Int
    public let code: String?

    public init(_ message: String, status: Int, code: String? = nil) {
        self.message = message
        self.status = status
        self.code = code
    }
}

extension ApiError: LocalizedError {
    public var errorDescription: String? { message }
}
