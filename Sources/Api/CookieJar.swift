import Foundation

/// 与桌面端 src/main/cookies.js 逐行对应的 Cookie 罐。gopan 是 Cookie 会话
/// （gopan_sess + gopan_csrf），自己管理罐子以便脱离 URLSession 做单元测试、
/// 并按桌面端相同的语义序列化到 Keychain 恢复会话。
/// 用数组保持插入序，保证 Cookie 头顺序与桌面端 JS Map 行为一致。
public struct Cookie: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    /// epoch 毫秒；nil 表示会话 Cookie
    public var expiresAt: Double?
    public var httpOnly: Bool
    public var sameSite: String

    public init(name: String, value: String, expiresAt: Double? = nil, httpOnly: Bool = false, sameSite: String = "lax") {
        self.name = name
        self.value = value
        self.expiresAt = expiresAt
        self.httpOnly = httpOnly
        self.sameSite = sameSite
    }
}

public struct CookieJar: Sendable {
    private var items: [Cookie] = []

    public init() {}

    public init(cookies: [Cookie]) {
        for c in cookies {
            items.append(c)
        }
    }

    public mutating func add(setCookieLines: [String], now: Date = Date()) {
        for line in setCookieLines {
            addOne(String(line), now: now)
        }
    }

    private mutating func addOne(_ header: String, now: Date) {
        let parts = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return }
        guard let eq = first.firstIndex(of: "="), eq != first.startIndex else { return }
        let name = String(first[first.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        var attrs: [String: String] = [:]
        for p in parts.dropFirst() {
            if let i = p.firstIndex(of: "="), i != p.startIndex {
                let k = String(p[p.startIndex..<i]).trimmingCharacters(in: .whitespaces).lowercased()
                attrs[k] = String(p[p.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            } else {
                attrs[p.trimmingCharacters(in: .whitespaces).lowercased()] = ""
            }
        }

        var expiresAt: Double?
        let nowMs = now.timeIntervalSince1970 * 1000
        if attrs["max-age"] != nil {
            if let secs = Double(attrs["max-age"] ?? ""), secs.isFinite {
                expiresAt = secs <= 0 ? 0 : nowMs + secs * 1000
            }
        } else if let expires = attrs["expires"], let t = Self.parseHTTPDate(expires) {
            expiresAt = t
        }

        let existing = items.firstIndex { $0.name == name }
        if expiresAt == 0 {
            if let existing { items.remove(at: existing) }
        } else {
            let cookie = Cookie(
                name: name,
                value: value,
                expiresAt: expiresAt,
                httpOnly: attrs["httponly"] != nil,
                sameSite: (attrs["samesite"] ?? "lax").lowercased()
            )
            if let existing {
                items[existing] = cookie // 已存在则原地更新，保持插入序（同 JS Map.set）
            } else {
                items.append(cookie)
            }
        }
    }

    public mutating func get(_ name: String) -> String? {
        guard let idx = items.firstIndex(where: { $0.name == name }) else { return nil }
        let c = items[idx]
        if let e = c.expiresAt, e <= Date().timeIntervalSince1970 * 1000 {
            items.remove(at: idx)
            return nil
        }
        return c.value
    }

    public mutating func header() -> String {
        prune()
        return items.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public mutating func clear() {
        items.removeAll()
    }

    public mutating func prune(now: Date = Date()) {
        let nowMs = now.timeIntervalSince1970 * 1000
        items.removeAll { c in
            if let e = c.expiresAt { return e <= nowMs }
            return false
        }
    }

    public func toJSON() -> [Cookie] {
        var copy = self
        copy.prune()
        return copy.items
    }

    // MARK: - HTTP date

    static func parseHTTPDate(_ value: String) -> Double? {
        let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: value) {
                return d.timeIntervalSince1970 * 1000
            }
        }
        return nil
    }
}
