import Foundation

/// 传输进度事件，字段与桌面端 ipc.js 广播给渲染层的负载一致。
public struct TransferEvent: Sendable {
    public enum Kind: String, Sendable {
        case upload
        case download
    }

    public let kind: Kind
    public let jobId: String
    public let name: String
    public let phase: String
    public let sent: Int64
    public let total: Int64
    /// retry 阶段的分片下标
    public let index: Int?
    /// retry 阶段的第几次尝试
    public let attempt: Int?
    /// error 阶段的消息
    public let message: String?

    public init(kind: Kind, jobId: String, name: String, phase: String, sent: Int64, total: Int64, index: Int? = nil, attempt: Int? = nil, message: String? = nil) {
        self.kind = kind
        self.jobId = jobId
        self.name = name
        self.phase = phase
        self.sent = sent
        self.total = total
        self.index = index
        self.attempt = attempt
        self.message = message
    }
}

/// 分片上传的断点续传记录持久化（路径|大小|mtime → uploadId），
/// 语义与桌面端 uploads.js 的 store 文档一致。
public protocol UploadResumeStore: AnyObject, Sendable {
    func loadAll() -> [String: String]
    func remember(key: String, uploadId: String)
    func forget(key: String)
}

/// JSON 文件实现，存放在 App 的 Application Support 目录。
public final class FileUploadResumeStore: UploadResumeStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(directory: URL) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("upload-resume.json"))
    }

    public func loadAll() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSON(data: data),
              let obj = json.objectValue else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v.stringValue { out[k] = s }
        }
        return out
    }

    public func remember(key: String, uploadId: String) {
        lock.lock(); defer { lock.unlock() }
        var doc = readLocked()
        doc[key] = uploadId
        writeLocked(doc)
    }

    public func forget(key: String) {
        lock.lock(); defer { lock.unlock() }
        var doc = readLocked()
        doc.removeValue(forKey: key)
        writeLocked(doc)
    }

    private func readLocked() -> [String: String] {
        loadAllLocked()
    }

    private func loadAllLocked() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSON(data: data),
              let obj = json.objectValue else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v.stringValue { out[k] = s }
        }
        return out
    }

    private func writeLocked(_ doc: [String: String]) {
        let payload = JSON(object: doc.mapValues { .string($0) })
        if let data = try? payload.encodedData() {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
