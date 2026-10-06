import Foundation

public enum ServerScope: String, Equatable, Sendable {
    case loopback
    case privateScope = "private"
    case publicScope = "public"
}

/// parseServerUrl 的结果。ok 为 false 时 reason 是给用户看的中文原因，
/// 其余字段仅在 ok 为 true 时有意义。
public struct ParsedServerUrl: Equatable, Sendable {
    public let ok: Bool
    public let url: String
    public let host: String
    public let secure: Bool
    public let scope: ServerScope
    public let needsAck: Bool
    public let reason: String

    static func fail(_ reason: String) -> ParsedServerUrl {
        ParsedServerUrl(ok: false, url: "", host: "", secure: false, scope: .publicScope, needsAck: false, reason: reason)
    }
}

/// 与桌面端 src/main/config.js 的 parseServerUrl 逐行对应：
/// 只接受站点根地址（http/https），拒绝带路径、账号密码和 .onion。
public enum ServerConfig {
    public static let defaultServerURL = "http://127.0.0.1:8787"

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    public static func parseServerURL(_ raw: String) -> ParsedServerUrl {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            return .fail("地址不能为空")
        }

        let schemePattern = "^[a-zA-Z][a-zA-Z0-9+.\\-]*://"
        let hasScheme = input.range(of: schemePattern, options: .regularExpression) != nil
        let withScheme = hasScheme ? input : "http://\(input)"

        guard let comps = URLComponents(string: withScheme), comps.scheme != nil else {
            return .fail("地址无法解析")
        }
        guard comps.scheme == "http" || comps.scheme == "https" else {
            return .fail("只支持 http 或 https")
        }
        if !(comps.user ?? "").isEmpty || !(comps.password ?? "").isEmpty {
            return .fail("地址里不能带账号密码")
        }
        guard let host = comps.host, !host.isEmpty else {
            return .fail("缺少主机名")
        }
        if host == ".onion" {
            return .fail("不支持 .onion 地址")
        }

        // 端口必须是纯数字（对应 WHATWG URL 对非法端口解析失败的行为）
        if let port = comps.port, port < 1 || port > 65535 {
            return .fail("地址无法解析")
        }
        // 显式拒绝 query 和 fragment（安卓端 normalize() 的同款规则）
        if !(comps.query ?? "").isEmpty || !(comps.fragment ?? "").isEmpty {
            return .fail("只能填站点根地址，不要带路径")
        }

        var path = comps.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.isEmpty {
            return .fail("只能填站点根地址，不要带路径")
        }

        let lowerHost = host.lowercased()
        // host:port 手工校验（URLComponents 对非法端口过宽）
        if let hostPort = Self.hostPortString(withScheme), !hostPort.hasPrefix("["), let colon = hostPort.firstIndex(of: ":") {
            let portText = hostPort[hostPort.index(after: colon)...]
            guard let p = Int(portText), (1...65535).contains(p) else {
                return .fail("地址无法解析")
            }
        }
        let scope: ServerScope
        if Self.loopbackHosts.contains(lowerHost) {
            scope = .loopback
        } else if isPrivateV4(lowerHost) {
            scope = .privateScope
        } else {
            scope = .publicScope
        }
        let secure = comps.scheme == "https"
        let portSuffix = comps.port.map { ":\($0)" } ?? ""
        return ParsedServerUrl(
            ok: true,
            url: "\(comps.scheme!)://\(host)\(portSuffix)",
            host: lowerHost,
            secure: secure,
            scope: scope,
            needsAck: !secure && scope == .publicScope,
            reason: ""
        )
    }

    /// 取出 "host[:port]" 段（跳过 scheme 与 userinfo），供端口合法性校验
    static func hostPortString(_ s: String) -> String? {
        guard let schemeEnd = s.range(of: "://") else { return nil }
        var rest = s[schemeEnd.upperBound...]
        if let at = rest.firstIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            return String(rest[...close])
        }
        let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        return String(rest[..<end])
    }

    static func isPrivateV4(_ host: String) -> Bool {
        let pattern = "^(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = host as NSString
        guard let m = regex.firstMatch(in: host, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 5 else {
            return false
        }
        let a = Int(ns.substring(with: m.range(at: 1))) ?? -1
        let b = Int(ns.substring(with: m.range(at: 2))) ?? -1
        return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)
    }
}
