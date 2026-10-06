import Foundation

/// 分片断点续传上传，移植自桌面端 src/main/uploads.js：
/// init 拿 uploadId/chunkSize → 轮询已收分片跳传 → 并发 2 上传分片 → complete。
/// 单片重试 4 次（指数退避 400ms 起）；401 / oversize / closed 不重试直接抛。
public final class UploadManager: @unchecked Sendable {
    public static let defaultChunkSize = 16 * 1024 * 1024

    private let client: DriveClient
    private let resumeStore: UploadResumeStore?
    private let onEvent: @Sendable (TransferEvent) -> Void
    private let lock = NSLock()
    private var active: [String: JobController] = [:]
    public var concurrency: Int = 2

    public init(client: DriveClient, resumeStore: UploadResumeStore? = nil, onEvent: @escaping @Sendable (TransferEvent) -> Void = { _ in }) {
        self.client = client
        self.resumeStore = resumeStore
        self.onEvent = onEvent
    }

    public static let cancelledError = ApiError("已取消上传", status: 0, code: "cancelled")
    public static let pausedError = ApiError("已暂停", status: 0, code: "paused")

    final class JobController: @unchecked Sendable {
        let jobId: String
        let stateLock = NSLock()
        var cancelled = false
        var paused = false
        var sent: Int64 = 0
        var total: Int64 = 0
        var name = ""
        var chunkSize = 0

        init(jobId: String) {
            self.jobId = jobId
        }

        var isCancelled: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return cancelled
        }

        var isPaused: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return paused
        }

        func cancel() {
            stateLock.lock(); cancelled = true; stateLock.unlock()
        }

        func pause() {
            stateLock.lock(); paused = true; stateLock.unlock()
        }
    }

    /// 供并发 worker 认领分片下标的共享游标
    final class Cursor: @unchecked Sendable {
        private let items: [Int]
        private let cursorLock = NSLock()
        private var i = 0

        init(_ items: [Int]) {
            self.items = items
        }

        func next() -> Int? {
            cursorLock.lock(); defer { cursorLock.unlock() }
            guard i < items.count else { return nil }
            defer { i += 1 }
            return items[i]
        }
    }

    static func resumeKey(localPath: URL, size: Int64, mtimeMs: Double) -> String {
        "\(localPath.path)|\(size)|\(Int(mtimeMs.rounded()))"
    }

    @discardableResult
    public func upload(localPath: URL, displayName: String? = nil, folderId: Int? = nil, jobId: String? = nil) async throws -> JSON {
        let attrs = try FileManager.default.attributesOfItem(atPath: localPath.path)
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            throw ApiError("只能上传普通文件", status: 0, code: nil)
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeMs = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
        let key = Self.resumeKey(localPath: localPath, size: size, mtimeMs: mtimeMs)
        let name = displayName ?? localPath.lastPathComponent
        let id = jobId ?? localPath.path

        let controller = JobController(jobId: id)
        controller.name = name
        controller.total = size
        lock.lock(); active[id] = controller; lock.unlock()
        defer {
            lock.lock(); active.removeValue(forKey: id); lock.unlock()
        }

        var uploadId: String?
        var done: Set<Int> = []
        if let store = resumeStore {
            uploadId = store.loadAll()[key]
        }
        if let existing = uploadId {
            do {
                let status = try await client.uploadStatus(uploadId: existing)
                if status["status"].string != "open" {
                    uploadId = nil // 服务端已完成或已放弃：从零开始
                } else {
                    done = Set(status["receivedChunks"].rows.compactMap { $0.intValue })
                    controller.stateLock.lock()
                    controller.chunkSize = status["chunkSize"].int
                    controller.sent = status["received"].int64
                    controller.stateLock.unlock()
                    emit(controller, "resuming")
                }
            } catch {
                uploadId = nil
            }
        }
        if uploadId == nil {
            let initResp = try await client.uploadInit(name: name, size: size, folderId: folderId)
            guard let newId = initResp["uploadId"].stringValue, !newId.isEmpty else {
                throw ApiError("上传初始化失败：服务端未返回 uploadId", status: 0, code: nil)
            }
            uploadId = newId
            resumeStore?.remember(key: key, uploadId: newId)
            controller.stateLock.lock()
            controller.chunkSize = initResp["chunkSize"].int
            controller.stateLock.unlock()
            emit(controller, "started")
        }
        guard let uploadId else {
            throw ApiError("上传初始化失败", status: 0, code: nil)
        }

        let chunkSize = {
            controller.stateLock.lock(); defer { controller.stateLock.unlock() }
            return controller.chunkSize > 0 ? controller.chunkSize : Self.defaultChunkSize
        }()
        let totalChunks = Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
        var pending: [Int] = []
        for i in 0..<totalChunks where !done.contains(i) {
            pending.append(i)
        }

        let cursor = Cursor(pending)
        let workerCount = max(1, min(concurrency, pending.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask { [weak self] in
                    guard let self else { return }
                    // 每个 worker 独立打开文件句柄（FileHandle 不是线程安全的）
                    let file = try FileHandle(forReadingFrom: localPath)
                    defer { try? file.close() }
                    while let index = cursor.next() {
                        if controller.isCancelled || controller.isPaused { return }
                        let chunkLen = Int(min(Int64(chunkSize), size - Int64(index) * Int64(chunkSize)))
                        guard chunkLen > 0 else { break }
                        try file.seek(toOffset: UInt64(index) * UInt64(chunkSize))
                        guard let buf = try file.read(upToCount: chunkLen), buf.count == chunkLen else {
                            throw ApiError("读取文件失败", status: 0, code: nil)
                        }
                        try await self.putChunk(uploadId: uploadId, index: index, data: buf, controller: controller)
                        controller.stateLock.lock()
                        controller.sent += Int64(chunkLen)
                        controller.stateLock.unlock()
                        self.emit(controller, "progress")
                    }
                }
            }
            try await group.waitForAll()
        }

        if controller.isPaused {
            // 暂停：不 abandon 服务端会话、不忘记断点记录，恢复时按 receivedChunks 跳传
            emit(controller, "paused")
            throw Self.pausedError
        }

        if controller.isCancelled {
            try? await client.uploadAbandon(uploadId: uploadId)
            resumeStore?.forget(key: key)
            emit(controller, "cancelled")
            throw Self.cancelledError
        }

        let res = try await client.uploadComplete(uploadId: uploadId, mime: MimeTypes.mimeFor(name))
        resumeStore?.forget(key: key)
        controller.stateLock.lock()
        controller.sent = controller.total
        controller.stateLock.unlock()
        emit(controller, "done")
        return res
    }

    private func putChunk(uploadId: String, index: Int, data: Data, controller: JobController) async throws {
        var delay: UInt64 = 400_000_000
        for attempt in 1...4 {
            if controller.isCancelled { return }
            if controller.isPaused { throw Self.pausedError }
            do {
                try await client.uploadChunk(uploadId: uploadId, index: index, data: data)
                return
            } catch let err as ApiError {
                // 会话失效或声明大小不匹配，重试永远不会成功
                if err.status == 401 || err.code == "oversize" || err.code == "closed" { throw err }
                if attempt == 4 { throw err }
                emit(controller, "retry", index: index, attempt: attempt)
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
    }

    public func cancel(jobId: String) {
        lock.lock(); defer { lock.unlock() }
        active[jobId]?.cancel()
    }

    /// 暂停：停止发片但保留服务端会话与断点记录
    public func pause(jobId: String) {
        lock.lock(); defer { lock.unlock() }
        active[jobId]?.pause()
    }

    private func emit(_ controller: JobController, _ phase: String, index: Int? = nil, attempt: Int? = nil, message: String? = nil) {
        controller.stateLock.lock()
        let sent = controller.sent, total = controller.total, name = controller.name
        controller.stateLock.unlock()
        onEvent(TransferEvent(kind: .upload, jobId: controller.jobId, name: name, phase: phase, sent: sent, total: total, index: index, attempt: attempt, message: message))
    }
}
