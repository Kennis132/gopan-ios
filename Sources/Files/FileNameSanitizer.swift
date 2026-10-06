import Foundation

/// 与桌面端 src/main/filenames.js 对应：本地保存名消毒 + 去重。
/// 注意保持与桌面端完全一致的输出（单元测试同源）。
public enum FileNameSanitizer {
    static let maxBase = 120

    static let reservedPattern = "^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\\..*)?$"
    static let forbiddenPattern = "[<>:\"|?*]"
    static let whitespacePattern = "\\s+"
    static let trailingDotsSpacesPattern = "[. ]+$"

    public static func sanitizeName(_ raw: String) -> String {
        // 去控制字符 U+0000–U+001F、U+007F–U+009F
        let cleanedScalars = raw.unicodeScalars.filter { !($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))

        let segments = cleaned
            .components(separatedBy: CharacterSet(charactersIn: "\\/"))
            .map { seg -> String in
                var s = seg.replacing(regex: forbiddenPattern, with: " ")
                s = s.replacing(regex: whitespacePattern, with: " ")
                s = s.trimmingCharacters(in: .whitespaces)
                s = s.replacing(regex: trailingDotsSpacesPattern, with: "")
                return s
            }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        var name = segments.joined(separator: " ")
        if name.isEmpty { name = "file" }
        if isReservedDeviceName(name) { name = "_" + name }

        let ext = extName(name)
        let base = baseName(name, droppingExtension: ext)
        if base.count > maxBase {
            name = String(base.prefix(maxBase)) + ext
        }
        return name
    }

    /// `a.png`, `a (2).png`, … — 绝不覆盖已有文件。
    public static func uniqueLocalName(in dir: URL, name: String, fileExists: (URL) -> Bool) -> String {
        let clean = sanitizeName(name)
        let ext = extName(clean)
        let base = baseName(clean, droppingExtension: ext)
        for i in 1...999 {
            let candidate = i == 1 ? clean : "\(base) (\(i))\(ext)"
            if !fileExists(dir.appendingPathComponent(candidate)) {
                return candidate
            }
        }
        return "\(base) (\(Int(Date().timeIntervalSince1970 * 1000)))\(ext)"
    }

    static func isReservedDeviceName(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: reservedPattern, options: [.caseInsensitive]) else { return false }
        let ns = name as NSString
        guard let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return false }
        return m.range.location == 0 && m.range.length == ns.length
    }

    /// node:path.extname 语义：末段点号在首位（.hidden）时返回空
    static func extName(_ name: String) -> String {
        guard let idx = name.lastIndex(of: "."), idx != name.startIndex else { return "" }
        return String(name[idx...])
    }

    /// node:path.basename(name, ext) 语义：仅在 name 以 ext 结尾时去掉
    static func baseName(_ name: String, droppingExtension ext: String) -> String {
        guard !ext.isEmpty, name.hasSuffix(ext) else { return name }
        return String(name.dropLast(ext.count))
    }
}

private extension String {
    func replacing(regex pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let ns = self as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: self, options: [], range: full, withTemplate: template)
    }
}
