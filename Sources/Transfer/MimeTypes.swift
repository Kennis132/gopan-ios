import Foundation

/// 与桌面端 uploads.js 的 MIME_BY_EXT 一致：只认我们明确支持的类型，其余 octet-stream。
public enum MimeTypes {
    static let byExtension: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "flac": "audio/flac", "m4a": "audio/mp4",
        "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm", "mkv": "video/x-matroska",
        "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "json": "application/json",
        "zip": "application/zip", "rar": "application/vnd.rar", "7z": "application/x-7z-compressed",
    ]

    public static func mimeFor(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return "application/octet-stream"
        }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return byExtension[ext] ?? "application/octet-stream"
    }
}
