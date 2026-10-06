import Foundation

/// 轻量 JSON 树。gopan API 的响应结构是动态的（与桌面端 client.js 一致，原样传递
/// JSON 而不是为每个端点建强类型模型），所以统一用这个枚举表示协议数据。
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: any)
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if String(cString: n.objCType) == "d" {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any]:
            self = .object(o.mapValues { JSON(any: $0) })
        default:
            self = .null
        }
    }

    var rawAny: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return NSNumber(value: b)
        case let .int(i): return NSNumber(value: i)
        case let .double(d): return NSNumber(value: d)
        case let .string(s): return s
        case let .array(a): return a.map { $0.rawAny }
        case let .object(o): return o.mapValues { $0.rawAny }
        }
    }

    /// 请求体编码。gopan 的请求体都是对象；顶层非对象时包一层保证合法。
    public func encodedData() throws -> Data {
        let any = rawAny
        if JSONSerialization.isValidJSONObject(any) {
            return try JSONSerialization.data(withJSONObject: any)
        }
        return try JSONSerialization.data(withJSONObject: [any])
    }
}

extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var object: [String: JSON] = [:]
        for (key, value) in elements {
            object[key] = value
        }
        self = .object(object)
    }
}

extension JSON: Identifiable {
    public var id: String { String(describing: self) }
}

public extension JSON {
    /// 文件/目录条目的稳定标识（列表 ForEach 用）
    var idValue: Int { self["id"].int }

    subscript(key: String) -> JSON {
        if case let .object(o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case let .array(a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int(d)
        default: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case let .int(i): return Int64(i)
        case let .double(d): return Int64(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }

    var arrayValue: [JSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var objectValue: [String: JSON]? {
        if case let .object(o) = self { return o }
        return nil
    }

    /// 便捷取值：类型不符时给零值（对应桌面端大量 `?.` 兜底写法）
    var string: String { stringValue ?? "" }
    var int: Int { intValue ?? 0 }
    var int64: Int64 { int64Value ?? 0 }
    var double: Double { doubleValue ?? 0 }
    var rows: [JSON] { arrayValue ?? [] }
}
