import Foundation
import SwiftUI

/// 服务器地址的可变包装：DriveClient 构造时捕获它，登录/切换服务器只改这里。
final class ServerURLBox: @unchecked Sendable {
    var url = ""
}

struct SessionData: Codable {
    var server: String
    var cookies: [Cookie]
    var username: String?
}

struct TransferRow: Identifiable {
    let id: String
    var name: String
    var phase: String
    var sent: Int64
    var total: Int64
}

@MainActor
final class AppState: ObservableObject {
    let vault = KeychainVault()
    let serverBox = ServerURLBox()

    lazy var client: DriveClient = {
        let box = serverBox
        return DriveClient(baseURLProvider: { box.url })
    }()

    lazy var uploadManager: UploadManager = {
        let c = client
        return UploadManager(
            client: c,
            resumeStore: FileUploadResumeStore(directory: Self.supportDirectory),
            onEvent: { [weak self] event in
                Task { @MainActor in self?.applyEvent(event) }
            }
        )
    }()

    lazy var downloadManager: DownloadManager = {
        let c = client
        return DownloadManager(
            client: c,
            getDir: { Self.documentsDirectory },
            onEvent: { [weak self] event in
                Task { @MainActor in self?.applyEvent(event) }
            }
        )
    }()

    // 登录页
    @Published var serverInput = ServerConfig.defaultServerURL
    @Published var username = ""
    @Published var password = ""
    @Published var isRegisterMode = false
    @Published var ackInsecure = false

    // 会话与站点
    @Published var bootstrapped = false
    @Published var loggedIn = false
    @Published var siteName = "篝火云盘"
    @Published var user: JSON?

    // 文件页
    @Published var currentFolderId: Int?
    @Published var crumbs: [JSON] = []
    @Published var folders: [JSON] = []
    @Published var files: [JSON] = []
    @Published var loading = false
    @Published var newFolderName = ""
    @Published var pendingRename: JSON?
    @Published var isRenamingFolder = false
    @Published var renameText = ""

    // 传输与提示
    @Published var transfers: [TransferRow] = []
    @Published var alertMessage: String?

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gopan", isDirectory: true)
    }

    // MARK: - 启动 / 会话

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if let raw = vault.get("session"),
           let data = raw.data(using: .utf8),
           let session = try? JSONDecoder().decode(SessionData.self, from: data) {
            serverBox.url = session.server
            serverInput = session.server
            username = session.username ?? ""
            if client.restoreJar(session.cookies) {
                loggedIn = true
                await loadSite()
                await refresh()
            }
        }
    }

    func saveSession() {
        let session = SessionData(server: serverBox.url, cookies: client.serializeJar(), username: username)
        if let data = try? JSONEncoder().encode(session), let text = String(data: data, encoding: .utf8) {
            try? vault.set(text, for: "session")
        }
    }

    func submitLogin() async {
        let parsed = ServerConfig.parseServerURL(serverInput)
        guard parsed.ok else {
            alertMessage = parsed.reason
            return
        }
        if parsed.needsAck && !ackInsecure {
            alertMessage = "对公网地址使用明文 HTTP 有风险，请先勾选确认"
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            alertMessage = "请输入用户名和密码"
            return
        }
        serverBox.url = parsed.url
        do {
            if isRegisterMode {
                _ = try await client.register(username, password)
            }
            let r = try await client.login(username, password)
            user = r["user"]
            loggedIn = true
            saveSession()
            await loadSite()
            await refresh()
        } catch {
            alertMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    func logout() async {
        try? await client.logout()
        client.resetSession()
        vault.unset("session")
        loggedIn = false
        user = nil
        folders = []
        files = []
        crumbs = []
        currentFolderId = nil
    }

    func loadSite() async {
        if let site = try? await client.site() {
            let name = site["name"].string
            siteName = name.isEmpty ? "篝火云盘" : name
        }
    }

    // MARK: - 文件

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await client.listFiles(folderId: currentFolderId)
            crumbs = r["breadcrumb"].rows
            folders = r["folders"].rows
            files = r["files"].rows
            saveSession()
        } catch is CancellationError {
        } catch {
            let apiError = error as? ApiError
            if apiError?.status == 401 {
                await logout()
            } else {
                alertMessage = apiError?.message ?? error.localizedDescription
            }
        }
    }

    func openFolder(_ folder: JSON) {
        currentFolderId = folder["id"].intValue
        Task { await refresh() }
    }

    func openCrumb(_ crumb: JSON?) {
        currentFolderId = crumb?["id"].intValue
        Task { await refresh() }
    }

    func mkdir(_ name: String) async {
        do {
            _ = try await client.mkdir(name, parentId: currentFolderId)
            await refresh()
        } catch {
            alertMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    func rename(_ item: JSON, isFolder: Bool, to newName: String) async {
        do {
            let id = item["id"].intValue
            _ = isFolder ? try await client.renameFolder(id: id, name: newName) : try await client.renameFile(id: id, name: newName)
            await refresh()
        } catch {
            alertMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    func delete(_ item: JSON, isFolder: Bool) async {
        do {
            let id = item["id"].intValue
            _ = isFolder ? try await client.deleteFolder(id: id) : try await client.deleteFile(id: id)
            await refresh()
        } catch {
            alertMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - 传输

    func uploadFiles(urls: [URL]) {
        for url in urls {
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try await uploadManager.upload(localPath: url, displayName: url.lastPathComponent, folderId: currentFolderId)
                } catch is CancellationError {
                } catch {
                    alertMessage = (error as? ApiError)?.message ?? error.localizedDescription
                }
            }
        }
    }

    func download(_ file: JSON) {
        let name = file["name"].string
        let size = file["size"].int64
        let id = file["id"].intValue
        Task {
            do {
                _ = try await downloadManager.start(fileId: id, name: name, size: size)
            } catch is CancellationError {
            } catch {
                alertMessage = (error as? ApiError)?.message ?? error.localizedDescription
            }
        }
    }

    private func applyEvent(_ event: TransferEvent) {
        let done = ["done", "cancelled", "error", "paused"].contains(event.phase)
        if done {
            transfers.removeAll { $0.id == event.jobId }
        } else {
            if let idx = transfers.firstIndex(where: { $0.id == event.jobId }) {
                transfers[idx].phase = event.phase
                transfers[idx].sent = event.sent
                transfers[idx].total = event.total
            } else {
                transfers.append(TransferRow(id: event.jobId, name: event.name, phase: event.phase, sent: event.sent, total: event.total))
            }
        }
        if event.phase == "error", let msg = event.message {
            alertMessage = msg
        }
    }
}

extension JSON {
    /// 文件/目录条目的稳定标识（列表 ForEach 用）
    var idValue: Int {
        self["id"].int
    }
}

/// 与安卓端 MainActivity.bytes 一致的字节可读化
enum ByteFormatter {
    static func format(_ bytes: Int64) -> String {
        let units: [String] = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unit])
    }
}
