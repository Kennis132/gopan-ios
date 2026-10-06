import Foundation
import Security

/// 凭据存储：桌面端用 safeStorage（DPAPI/Keychain/libsecret）加密文件，
/// iOS 直接用系统 Keychain（kSecClassGenericPassword），天然按 App 沙箱隔离加密。
/// 接口语义与桌面端 vault.js 一致：set / get / unset / clear。
public struct KeychainVault: Sendable {
    public let service: String

    public init(service: String = "cn.hcy.gopan.vault") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func set(_ text: String, for name: String) throws {
        let data = Data(text.utf8)
        var query = baseQuery(account: name)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ApiError("Keychain 写入失败 (\(status))", status: 0, code: "keychain")
        }
    }

    public func get(_ name: String) -> String? {
        var query = baseQuery(account: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func unset(_ name: String) {
        SecItemDelete(baseQuery(account: name) as CFDictionary)
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
