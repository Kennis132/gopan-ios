import Foundation

// MARK: - 传输任务模型（对标安卓 TaskStore / TransferCenter 的任务记录）

enum TransferState: String, Codable {
    case queued, running, paused, failed, done, cancelled
}

struct TransferTask: Codable, Identifiable, Equatable {
    var id: String
    /// "upload" | "download"
    var kind: String
    var name: String
    var size: Int64
    var done: Int64
    var state: TransferState
    var speed: Int64
    var eta: Int64
    var error: String
    var createdAt: Double
    /// 下载完成后本地路径；上传时为本地源文件路径（"另存为/打开文件"用）
    var localPath: String
    var targetFolder: Int?
    /// 下载任务对应的服务端文件 id（恢复断点需要）
    var fileId: Int = 0

    static func new(kind: String, name: String, size: Int64, targetFolder: Int?) -> TransferTask {
        TransferTask(
            id: UUID().uuidString,
            kind: kind,
            name: name,
            size: size,
            done: 0,
            state: .queued,
            speed: 0,
            eta: -1,
            error: "",
            createdAt: Date().timeIntervalSince1970 * 1000,
            localPath: "",
            targetFolder: targetFolder
        )
    }

    var isActive: Bool { state != .done && state != .cancelled }
}

// MARK: - 速率采样器（逐行对标安卓 TransferRate.java）

struct TransferRate {
    private var prevBytes: Int64 = -1
    private var prevTime: Double = 0
    private(set) var rate: Int64 = 0

    mutating func sample(_ bytes: Int64, now: Double = Date().timeIntervalSince1970 * 1000) -> Int64 {
        if prevBytes < 0 || bytes < prevBytes || now < prevTime {
            prevBytes = bytes
            prevTime = now
            rate = 0
            return 0
        }
        let elapsed = now - prevTime
        if elapsed < 1000 { return rate }
        let measured = Int64(Double(bytes - prevBytes) * 1000.0 / elapsed)
        rate = rate == 0 ? measured : Int64(Double(rate) * 0.65 + Double(measured) * 0.35)
        prevBytes = bytes
        prevTime = now
        return rate
    }

    static func remaining(size: Int64, done: Int64, rate: Int64) -> Int64 {
        if size <= 0 || rate <= 0 { return -1 }
        return Int64(ceil(Double(size - done) / Double(rate)))
    }

    /// ETA 文案（对标安卓 TransferRate.time）
    static func time(_ s: Int64) -> String {
        if s < 0 { return "正在计算" }
        if s < 60 { return "约 \(max(1, Int(s))) 秒" }
        let minutes = (Int(s) + 59) / 60
        if minutes < 60 { return "约 \(minutes) 分钟" }
        return "约 \(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

// MARK: - 任务持久化（对标安卓 TaskStore：JSON 文件）

protocol TransferStoreProtocol: AnyObject, Sendable {
    func loadAll() -> [TransferTask]
    func saveAll(_ tasks: [TransferTask])
    func update(_ id: String, patch: (inout TransferTask) -> Void)
    func remove(_ id: String)
    func removeWhere(_ predicate: (TransferTask) -> Bool)
}

final class TransferStore: TransferStoreProtocol, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var tasks: [TransferTask] = []
    private var loaded = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? fileURL.deletingLastPathComponent().ensureDir()
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TransferTask].self, from: data) else { return }
        tasks = list.sorted { $0.createdAt > $1.createdAt }
    }

    func loadAll() -> [TransferTask] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return tasks
    }

    func saveAll(_ list: [TransferTask]) {
        lock.lock(); defer { lock.unlock() }
        tasks = list.sorted { $0.createdAt > $1.createdAt }
        persist()
    }

    func update(_ id: String, patch: (inout TransferTask) -> Void) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        patch(&tasks[idx])
        persist()
    }

    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        tasks.removeAll { $0.id == id }
        persist()
    }

    func removeWhere(_ predicate: (TransferTask) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        tasks.removeAll(where: predicate)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tasks) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

private extension URL {
    func ensureDir() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
