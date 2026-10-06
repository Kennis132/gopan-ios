import Foundation
import CryptoKit

/// Range 断点续传下载，移植自桌面端 src/main/downloads.js：
/// 先写 `.part` 临时文件 → 带Range 续传（服务器回 200 则重头下）→ 完整性校验（字节数 + 可选 sha256）→ 原子改名。
/// 取消时保留 `.part`，下次自动从断点续传。
public final class DownloadManager: @unchecked Sendable {
    private let client: DriveClient
    private let getDir: @Sendable () -> URL
    private let onEvent: @Sendable (TransferEvent) -> Void
    private let lock = NSLock()
    private var active: [String: DownloadJob] = [:]

    public init(client: DriveClient, getDir: @escaping @Sendable () -> URL, onEvent: @escaping @Sendable (TransferEvent) -> Void = { _ in }) {
        self.client = client
        self.getDir = getDir
        self.onEvent = onEvent
    }

    public struct Result: Sendable {
        public let ok: Bool
        public var cancelled = false
        public var incomplete = false
        public var checksumMismatch = false
        public let path: URL
        public let partialPath: URL
        public let name: String
        public let size: Int64
        public let verified: Bool
        public let expectedChecksum: String?
        public let actualChecksum: String?
        public let message: String?
    }

    final class DownloadJob: @unchecked Sendable {
        let jobId: String
        let path: URL
        let name: String
        let stateLock = NSLock()
        var cancelled = false
        var received: Int64 = 0
        var total: Int64 = 0

        init(jobId: String, path: URL, name: String) {
            self.jobId = jobId
            self.path = path
            self.name = name
        }

        var isCancelled: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return cancelled
        }

        func cancel() {
            stateLock.lock(); cancelled = true; stateLock.unlock()
        }
    }

    @discardableResult
    public func start(fileId: Int?, name: String, size: Int64, pathname: String? = nil, sha256: String? = nil, targetDir: URL? = nil, jobId givenId: String? = nil) async throws -> Result {
        let fm = FileManager.default
        let dir = targetDir ?? getDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let sanitized = FileNameSanitizer.sanitizeName(name)
        let finalName = FileNameSanitizer.uniqueLocalName(in: dir, name: sanitized) { fm.fileExists(atPath: $0.path) }
        let finalPath = dir.appendingPathComponent(finalName)
        let partPath = URL(fileURLWithPath: finalPath.path + ".part")
        let jobId = givenId ?? "dl-\(fileId.map(String.init) ?? finalName)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let urlPath = pathname ?? "/api/files/\(fileId ?? 0)/download"

        let job = DownloadJob(jobId: jobId, path: finalPath, name: finalName)
        job.total = size
        lock.lock(); active[jobId] = job; lock.unlock()

        func finish(_ result: Result) -> Result {
            lock.lock(); active.removeValue(forKey: jobId); lock.unlock()
            return result
        }

        let existing = (try? fm.attributesOfItem(atPath: partPath.path)[.size] as? NSNumber)?.int64Value ?? 0

        let request = try client.makeStreamRequest(pathname: urlPath, range: existing > 0 ? "bytes=\(existing)-" : nil)
        let session = URLSession.shared
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            let err = TransferEvent(kind: .download, jobId: jobId, name: finalName, phase: "error", sent: 0, total: job.total, message: "无法连接服务器（\(error.localizedDescription)）")
            onEvent(err)
            throw ApiError("无法连接服务器（\(error.localizedDescription)）", status: 0, code: "network")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApiError("无法连接服务器（无有效响应）", status: 0, code: "network")
        }
        client.noteResponse(http)

        if http.statusCode != 200 && http.statusCode != 206 {
            var first = Data()
            for try await b in bytes {
                first.append(b)
                if first.count > 64 * 1024 { break }
            }
            var msg = "下载失败 (\(http.statusCode))"
            if let parsed = try? JSON(data: first), let serverError = parsed["error"].stringValue, !serverError.isEmpty {
                msg = serverError
            }
            onEvent(TransferEvent(kind: .download, jobId: jobId, name: finalName, phase: "error", sent: 0, total: job.total, message: msg))
            throw ApiError(msg, status: http.statusCode, code: nil)
        }

        var start = existing
        if http.statusCode == 200 && existing > 0 {
            // 这次响应不支持 Range：丢弃已有分片重下
            start = 0
            try? Data().write(to: partPath)
        }
        let contentLength = http.expectedContentLength > 0 ? Int64(http.expectedContentLength) : 0
        let totalFromHeaders = Self.parseTotal(http.value(forHTTPHeaderField: "Content-Range"), start: start, contentLength: contentLength)
        job.stateLock.lock()
        if totalFromHeaders > job.total { job.total = totalFromHeaders }
        job.received = start
        job.stateLock.unlock()
        emit(job, "progress")

        // 追加写 .part
        if !fm.fileExists(atPath: partPath.path) {
            fm.createFile(atPath: partPath.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partPath)
        if start == 0 {
            try handle.truncate(atOffset: 0)
        } else {
            try handle.seekToEnd()
        }

        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        var received = start
        var writeError: Error?
        do {
            for try await byte in bytes {
                if job.isCancelled { break }
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    job.stateLock.lock()
                    job.received = received
                    job.stateLock.unlock()
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                job.stateLock.lock()
                job.received = received
                job.stateLock.unlock()
            }
        } catch {
            writeError = error
        }
        try? handle.close()

        if let writeError {
            onEvent(TransferEvent(kind: .download, jobId: jobId, name: finalName, phase: "error", sent: job.received, total: job.total, message: writeError.localizedDescription))
            throw writeError
        }

        if job.isCancelled {
            emit(job, "paused")
            return finish(Result(ok: false, cancelled: true, path: finalPath, partialPath: partPath, name: finalName, size: job.received, verified: false, expectedChecksum: nil, actualChecksum: nil, message: nil))
        }

        let written = (try? fm.attributesOfItem(atPath: partPath.path)[.size] as? NSNumber)?.int64Value ?? 0
        job.stateLock.lock()
        let expectedTotal = job.total
        job.stateLock.unlock()
        if expectedTotal > 0 && written != expectedTotal {
            let msg = "下载不完整：\(written)/\(expectedTotal) 字节，可重试续传"
            onEvent(TransferEvent(kind: .download, jobId: jobId, name: finalName, phase: "error", sent: written, total: expectedTotal, message: msg))
            return finish(Result(ok: false, incomplete: true, path: finalPath, partialPath: partPath, name: finalName, size: written, verified: false, expectedChecksum: nil, actualChecksum: nil, message: msg))
        }

        if fm.fileExists(atPath: finalPath.path) {
            try? fm.removeItem(at: finalPath)
        }
        try fm.moveItem(at: partPath, to: finalPath)

        if let sha256, !sha256.isEmpty {
            let actual = try Self.sha256Hex(of: finalPath)
            let expected = sha256.lowercased()
            if actual != expected {
                try? fm.removeItem(at: finalPath)
                let msg = "校验和不匹配，已删除下载的文件"
                onEvent(TransferEvent(kind: .download, jobId: jobId, name: finalName, phase: "error", sent: written, total: expectedTotal, message: msg))
                return finish(Result(ok: false, checksumMismatch: true, path: finalPath, partialPath: partPath, name: finalName, size: written, verified: false, expectedChecksum: expected, actualChecksum: actual, message: msg))
            }
        }

        emit(job, "done")
        return finish(Result(ok: true, path: finalPath, partialPath: partPath, name: finalName, size: written, verified: !(sha256 ?? "").isEmpty, expectedChecksum: nil, actualChecksum: nil, message: nil))
    }

    public func cancel(jobId: String) {
        lock.lock(); defer { lock.unlock() }
        active[jobId]?.cancel()
    }

    /// 取消并丢弃 .part（显式放弃断点）
    public func cancelAndDiscard(jobId: String) {
        lock.lock()
        let job = active[jobId]
        lock.unlock()
        guard let job else { return }
        job.cancel()
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: job.path.path + ".part"))
    }

    private func emit(_ job: DownloadJob, _ phase: String, message: String? = nil) {
        job.stateLock.lock()
        let received = job.received, total = job.total
        job.stateLock.unlock()
        onEvent(TransferEvent(kind: .download, jobId: job.jobId, name: job.name, phase: phase, sent: received, total: total, message: message))
    }

    /// Content-Range 里的总大小；没有则用 start + content-length 兜底
    static func parseTotal(_ contentRange: String?, start: Int64, contentLength: Int64) -> Int64 {
        if let range = contentRange, let m = range.range(of: "/(\\d+)\\s*$", options: .regularExpression) {
            return Int64(range[m].dropFirst().trimmingCharacters(in: .whitespaces)) ?? 0
        }
        if contentLength > 0 { return start + contentLength }
        return 0
    }

    static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
