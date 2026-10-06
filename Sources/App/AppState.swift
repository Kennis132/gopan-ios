import Foundation
import SwiftUI
import Network

/// 服务器地址的可变包装：DriveClient 构造时捕获它，登录/切换服务器只改这里。
final class ServerURLBox: @unchecked Sendable {
    var url = ""
}

struct SessionData: Codable {
    var server: String
    var cookies: [Cookie]
    var username: String?
}

/// 页面路由（对标安卓 page: main/recycle/settings/shares + tab 0-4）
enum GPage: String {
    case main, recycle, settings, shares
}

/// 弹层上下文
struct FileActionContext: Identifiable {
    let id = UUID()
    var item: JSON
    var isDirectory: Bool
    var recycle = false
}

struct NameDialogConfig: Identifiable {
    let id = UUID()
    var title: String
    var initial: String
    /// 提交回调目标：item 为空表示新建文件夹
    var item: JSON?
    var isFolder: Bool
}

struct MoveConfig: Identifiable {
    let id = UUID()
    var title: String
    var items: [JSON]
    var isFolders: [Bool]
    var excludedFolderIds: Set<Int>
}

struct ShareComposerContext: Identifiable {
    let id = UUID()
    var file: JSON
}

struct UserSheetContext: Identifiable {
    let id = UUID()
    var username: String
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - 路由与全局

    @Published var page: GPage = .main
    @Published var tab = 0
    @Published var booting = true
    @Published var notice: String?
    @Published var failure: String?
    @Published var confirm: ConfirmConfig?
    @Published var previewFile: JSON?

    // MARK: - 会话与站点

    let vault = KeychainVault()
    let serverBox = ServerURLBox()

    lazy var client: DriveClient = {
        let box = serverBox
        return DriveClient(baseURLProvider: { box.url })
    }()

    @Published var user: JSON?
    @Published var site: JSON = .object([:])
    @Published var siteLoaded = false

    // MARK: - 设置（对标安卓 prefs：theme/accent/grid/sort/wifi/messages）

    @AppStorage("theme") var themeMode: String = "system"
    @AppStorage("accent") var accentIndex: Int = 0
    @AppStorage("grid") var grid: Bool = false
    @AppStorage("sort") var sort: Int = 0
    @AppStorage("wifi") var wifiOnly: Bool = false
    @AppStorage("messages") var messageNotify: Bool = false
    @AppStorage("username") var savedUsername: String = ""

    // MARK: - Welcome

    @Published var loginServer = ""
    @Published var loginUsername = ""
    @Published var loginPassword = ""
    @Published var loginReveal = false
    @Published var loginRegister = false
    @Published var loginBusy = false
    @Published var loginError = ""
    @Published var confirmHTTP = false

    // MARK: - 文件页

    @Published var folderId: Int?
    @Published var breadcrumb: [JSON] = []
    @Published var folders: [JSON] = []
    @Published var files: [JSON] = []
    @Published var query = ""
    @Published var category = 0
    @Published var selected = Set<String>()
    @Published var loadingFiles = false

    // MARK: - 其他页面数据

    @Published var shares: [JSON] = []
    @Published var recycleFolders: [JSON] = []
    @Published var recycleFiles: [JSON] = []
    @Published var messages: [JSON] = []
    @Published var transferTasks: [TransferTask] = []
    @Published var transferSegment = 0
    @Published var publicProfile: JSON?

    // MARK: - 传输引擎

    lazy var uploadManager: UploadManager = {
        let c = client
        let state = self
        return UploadManager(client: c, resumeStore: resumeStore) { event in
            Task { @MainActor in state.handleTransferEvent(event) }
        }
    }()

    lazy var downloadManager: DownloadManager = {
        let c = client
        let state = self
        return DownloadManager(client: c, getDir: { Self.documentsDirectory }) { event in
            Task { @MainActor in state.handleTransferEvent(event) }
        }
    }()

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gopan", isDirectory: true)
    }

    let transferStore: TransferStore
    let resumeStore: FileUploadResumeStore
    private var runners: [String: Task<Void, Never>] = [:]
    private var rates: [String: TransferRate] = [:]
    /// 每个任务收到停止信号后的期望终态："pause" | "cancel"
    private var pendingStop: [String: String] = [:]
    private let pathMonitor = NWPathMonitor()
    private var pathIsExpensive = true

    // MARK: - 弹层状态

    @Published var fileActions: FileActionContext?
    @Published var nameDialog: NameDialogConfig?
    @Published var shareComposer: ShareComposerContext?
    @Published var moveChooser: MoveConfig?
    @Published var showShareViewer = false
    @Published var showPasswordSheet = false
    @Published var showSessionSheet = false
    @Published var showEditProfile = false
    @Published var showMessageComposer = false
    @Published var userSheet: UserSheetContext?

    var siteName: String {
        let n = site["name"].string
        return n.isEmpty ? "篝火云盘" : n
    }

    var displayName: String {
        let dn = user?["display_name"].string ?? ""
        return dn.isEmpty ? (user?["username"].string ?? "") : dn
    }

    var limits: JSON {
        site["limits"].objectValue != nil ? site["limits"] : .object([:])
    }

    init() {
        transferStore = TransferStore(fileURL: Self.supportDirectory.appendingPathComponent("transfers.json"))
        resumeStore = FileUploadResumeStore(directory: Self.supportDirectory)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathIsExpensive = path.isExpensive || path.isConstrained
                self?.pumpTransfers()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "gopan.path"))
    }

    // MARK: - 启动 / 会话

    func bootstrap() async {
        guard booting else { return }
        if let raw = vault.get("session"),
           let data = raw.data(using: .utf8),
           let session = try? JSONDecoder().decode(SessionData.self, from: data) {
            serverBox.url = session.server
            loginServer = session.server
            loginUsername = session.username ?? ""
            if client.restoreJar(session.cookies) {
                await loadProfile()
                if user != nil {
                    await load()
                    await loadSite()
                }
            }
        }
        // 重启后发现 running/queued 但没有进程的任务 → 置 paused（对标安卓）
        for t in transferStore.loadAll() where t.isActive {
            if runners[t.id] == nil {
                transferStore.update(t.id) {
                    $0.state = .paused
                    $0.error = "任务已中断，点击继续可恢复断点"
                }
            }
        }
        syncTasks()
        booting = false
    }

    func saveSession() {
        let session = SessionData(server: serverBox.url, cookies: client.serializeJar(), username: loginUsername)
        if let data = try? JSONEncoder().encode(session), let text = String(data: data, encoding: .utf8) {
            try? vault.set(text, for: "session")
        }
    }

    func loadProfile() async {
        do {
            let r = try await client.me()
            user = r["user"]
        } catch {
            handle(error)
        }
    }

    func loadSite() async {
        if let s = try? await client.site() {
            site = s
            siteLoaded = true
        }
    }

    // MARK: - 登录 / 登出

    /// 对标安卓 normalizeServer：无协议头默认 https
    static func normalizeServer(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
        return "https://" + t
    }

    func submitLogin() async {
        let server = Self.normalizeServer(loginServer)
        guard !server.isEmpty else { loginError = "请输入服务器地址"; return }
        loginError = ""
        loginBusy = true
        defer { loginBusy = false }
        let parsed = ServerConfig.parseServerURL(server)
        guard parsed.ok else { loginError = parsed.reason; return }
        serverBox.url = parsed.url
        do {
            let s = try await client.site()
            site = s
            siteLoaded = true
            if loginRegister && !s["registrationOpen"].bool {
                loginError = "站点未开放注册"
                return
            }
            let trimmedName = loginUsername.trimmingCharacters(in: .whitespaces)
            if loginRegister {
                _ = try await client.register(trimmedName, loginPassword)
            }
            _ = try await client.login(trimmedName, loginPassword)
            savedUsername = trimmedName
            user = try await client.me()["user"]
            saveSession()
            tab = 0
            page = .main
            selected = []
            failure = nil
            await load()
        } catch {
            let api = error as? ApiError
            if api?.code == "registration_closed" {
                loginError = "站点未开放注册"
            } else if api?.status == 401 {
                loginError = "用户名或密码不正确"
            } else {
                loginError = api?.message ?? error.localizedDescription
            }
            client.resetSession()
        }
    }

    func logout() async {
        pauseAllTasks()
        try? await client.logout()
        client.resetSession()
        vault.unset("session")
        user = nil
        page = .main
        tab = 0
        folders = []
        files = []
        breadcrumb = []
        selected = []
    }

    func switchServer() async {
        pauseAllTasks()
        client.resetSession()
        vault.unset("session")
        user = nil
        loginServer = ""
        loginPassword = ""
        page = .main
        tab = 0
    }

    // MARK: - 数据加载（对标安卓 DriveState.load）

    func load() async {
        failure = nil
        if page == .recycle {
            await loadRecycle()
        } else if page == .shares || tab == 2 {
            await loadShares()
        } else if tab == 0 {
            await loadFiles()
        } else if tab == 1 {
            syncTasks()
        } else if tab == 3 {
            await loadSite()
            await loadMessages()
        } else if tab == 4 {
            await loadProfile()
        }
    }

    func refresh() async {
        await load()
    }

    func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let r = try await client.listFiles(folderId: folderId)
            breadcrumb = r["breadcrumb"].rows
            folders = r["folders"].rows
            files = r["files"].rows
            saveSession()
        } catch {
            handle(error)
        }
    }

    func enter(_ folder: JSON?) {
        folderId = folder?["id"].intValue
        query = ""
        selected = []
        Task { await loadFiles() }
    }

    func loadRecycle() async {
        do {
            let r = try await client.recycleList()
            recycleFolders = r["folders"].rows
            recycleFiles = r["files"].rows
        } catch {
            handle(error)
        }
    }

    func loadShares() async {
        do {
            let r = try await client.listShares()
            shares = r["shares"].rows
        } catch {
            handle(error)
        }
    }

    func loadMessages() async {
        do {
            let r = try await client.guestbook(limit: 100)
            messages = r["messages"].rows
        } catch {
            handle(error)
        }
    }

    /// 401 → 强制登出（传输断点保留），其余显示错误横幅
    func handle(_ error: Error) {
        let api = error as? ApiError
        if api?.status == 401 {
            Task { await logout() }
            failure = "登录已过期，请重新登录。传输断点已保留。"
        } else if api?.code == "cancelled" || api?.code == "paused" {
            // 主动暂停/取消不算失败
        } else {
            failure = api?.message ?? "连接中断，请重试"
        }
    }

    func showNotice(_ text: String) {
        notice = text
        let text = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if notice == text { notice = nil }
        }
    }

    // MARK: - 文件操作

    func mkdir(_ name: String) async {
        do {
            _ = try await client.mkdir(name.trimmingCharacters(in: .whitespaces), parentId: folderId)
            showNotice("已完成")
            await loadFiles()
        } catch {
            handle(error)
        }
    }

    func rename(_ item: JSON, isFolder: Bool, to newName: String) async {
        do {
            let id = item["id"].int
            _ = isFolder ? try await client.renameFolder(id: id, name: newName) : try await client.renameFile(id: id, name: newName)
            showNotice("已完成")
            await load()
        } catch {
            handle(error)
        }
    }

    func moveToRecycle(_ item: JSON, isFolder: Bool) async {
        do {
            let id = item["id"].int
            _ = isFolder ? try await client.deleteFolder(id: id) : try await client.deleteFile(id: id)
            showNotice("已完成")
            selected.removeAll()
            await load()
        } catch {
            handle(error)
        }
    }

    func move(_ item: JSON, isFolder: Bool, to target: Int?) async {
        do {
            let id = item["id"].int
            if isFolder {
                _ = try await client.moveFolder(id: id, folderId: target ?? 0)
            } else {
                _ = try await client.moveFile(id: id, folderId: target ?? 0)
            }
            showNotice("已完成")
            await loadFiles()
        } catch {
            handle(error)
        }
    }

    func toggleSelect(_ item: JSON, isDirectory: Bool) {
        let key = (isDirectory ? "d" : "f") + String(item["id"].int)
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }

    func selectionItems() -> (dirs: [JSON], files: [JSON]) {
        let dirs = folders.filter { selected.contains("d" + String($0["id"].int)) }
        let selFiles = files.filter { selected.contains("f" + String($0["id"].int)) }
        return (dirs, selFiles)
    }

    func batchDelete() async {
        let (dirs, selFiles) = selectionItems()
        let total = dirs.count + selFiles.count
        for d in dirs {
            _ = try? await client.deleteFolder(id: d["id"].int)
        }
        for f in selFiles {
            _ = try? await client.deleteFile(id: f["id"].int)
        }
        selected.removeAll()
        showNotice("已处理 \(total) 项")
        await loadFiles()
    }

    func batchDownload() {
        let (_, selFiles) = selectionItems()
        let total = selFiles.count
        for f in selFiles {
            queueDownload(file: f, notice: false)
        }
        selected.removeAll()
        showNotice("已处理 \(total) 项")
    }

    func batchMove(to target: Int?) async {
        let (dirs, selFiles) = selectionItems()
        let total = dirs.count + selFiles.count
        for d in dirs {
            _ = try? await client.moveFolder(id: d["id"].int, folderId: target ?? 0)
        }
        for f in selFiles {
            _ = try? await client.moveFile(id: f["id"].int, folderId: target ?? 0)
        }
        selected.removeAll()
        showNotice("已移动 \(total) 项")
        await loadFiles()
    }

    // MARK: - 回收站操作

    func restoreRecycle(_ item: JSON, isFolder: Bool) async {
        do {
            let id = item["id"].int
            _ = isFolder ? try await client.restoreFolder(id: id) : try await client.restoreFile(id: id)
            showNotice("已完成")
            await loadRecycle()
        } catch {
            handle(error)
        }
    }

    func purgeRecycle(_ item: JSON, isFolder: Bool) async {
        do {
            let id = item["id"].int
            _ = isFolder ? try await client.purgeFolder(id: id) : try await client.purgeFile(id: id)
            showNotice("已完成")
            await loadRecycle()
        } catch {
            handle(error)
        }
    }

    // MARK: - 分享

    func createShare(fileId: Int, expiresIn: Int?, password: String?, maxHits: Int?, visibility: String) async throws -> JSON {
        try await client.createShare([
            "fileId": .int(fileId),
            "expiresIn": expiresIn.map(JSON.int) ?? .null,
            "password": (password?.isEmpty ?? true) ? .null : .string(password!),
            "maxHits": maxHits.map(JSON.int) ?? .null,
            "visibility": .string(visibility),
        ])
    }

    func toggleShareVisibility(_ share: JSON) async {
        let next = share["visibility"].string == "public" ? "private" : "public"
        do {
            _ = try await client.patchShare(id: share["id"].int, visibility: next)
            showNotice("已完成")
            await loadShares()
        } catch {
            handle(error)
        }
    }

    func revokeShare(_ share: JSON) async {
        do {
            _ = try await client.deleteShare(id: share["id"].int)
            showNotice("已完成")
            await loadShares()
        } catch {
            handle(error)
        }
    }

    // MARK: - 留言板

    func postMessage(_ text: String) async {
        do {
            _ = try await client.postGuestbook(text)
            showNotice("留言已发布")
            await loadMessages()
        } catch {
            handle(error)
        }
    }

    func deleteMessage(_ m: JSON) async {
        do {
            _ = try await client.deleteGuestbook(id: m["id"].int)
            showNotice("已完成")
            await loadMessages()
        } catch {
            handle(error)
        }
    }

    // MARK: - 资料

    func saveProfile(_ displayName: String, bio: String) async {
        do {
            let r = try await client.updateProfile(displayName, bio)
            user = r["profile"]
            showNotice("资料已更新")
        } catch {
            handle(error)
        }
    }

    func removeAvatar() async {
        do {
            let r = try await client.removeAvatar()
            user = r["profile"]
            showNotice("头像已移除")
        } catch {
            handle(error)
        }
    }

    func uploadAvatarImage(_ uiImage: UIImage) async {
        do {
            guard let data = Self.processAvatar(uiImage) else {
                failure = "无法识别图片格式"
                return
            }
            let maxBytes = site["limits"]["avatarMaxBytes"].int64 == 0 ? 2 * 1024 * 1024 : site["limits"]["avatarMaxBytes"].int64
            if Int64(data.count) > maxBytes {
                failure = "头像超过站点大小限制"
                return
            }
            let r = try await client.uploadAvatar(data, contentType: "image/jpeg")
            user = r["profile"]
            showNotice("头像已更新")
        } catch {
            handle(error)
        }
    }

    /// 头像管线（对标安卓）：居中裁方 → 512×512 JPEG 质量 90
    static func processAvatar(_ image: UIImage) -> Data? {
        let target = 512.0
        let side = min(image.size.width, image.size.height)
        guard side > 0, let cg = image.cgImage?.cropping(to: CGRect(origin: CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2), size: CGSize(width: side, height: side))) else { return nil }
        let square = UIImage(cgImage: cg, scale: 1, orientation: image.imageOrientation)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target))
        let resized = renderer.image { _ in
            square.draw(in: CGRect(x: 0, y: 0, width: target, height: target))
        }
        return resized.jpegData(compressionQuality: 0.9)
    }

    func changePassword(old: String, next: String) async -> Bool {
        do {
            _ = try await client.changePassword(old, next)
            showNotice("密码已更新")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func revokeSessions() async {
        do {
            let r = try await client.revokeOtherSessions()
            showNotice("已退出 \(r["revoked"].int) 个其他会话")
        } catch {
            handle(error)
        }
    }

    func loadPublicUser(_ username: String) async {
        do {
            publicProfile = try await client.usersPublicProfile(username)
        } catch {
            handle(error)
        }
    }

    // MARK: - 传输中心（对标安卓 Transfers/TransferCenter/TaskStore）

    private func syncTasks() {
        transferTasks = transferStore.loadAll()
    }

    func refreshTasks() {
        syncTasks()
    }

    /// 传输事件 → 任务记录 + 速率采样（对标安卓 TransferRate EMA）
    func handleTransferEvent(_ event: TransferEvent) {
        let id = event.jobId
        guard transferStore.loadAll().contains(where: { $0.id == id }) else { return }
        var rate = rates[id] ?? TransferRate()
        let sp = rate.sample(event.sent)
        rates[id] = rate
        let eta = TransferRate.remaining(size: event.total, done: event.sent, rate: sp)
        transferStore.update(id) {
            $0.done = event.sent
            $0.size = max($0.size, event.total)
            $0.speed = sp
            $0.eta = eta
        }
        syncTasks()
    }

    func queueUpload(localURL original: URL, displayName: String? = nil, folderId: Int? = nil) {
        // fileImporter 的安全作用域 URL 是临时的：先拷贝进私有目录保证断点恢复（重 IO 放后台）
        Task.detached { [weak self] in
            let name = displayName ?? original.lastPathComponent
            let scoped = original.startAccessingSecurityScopedResource()
            defer { if scoped { original.stopAccessingSecurityScopedResource() } }
            let dest = Self.supportDirectory.appendingPathComponent("incoming", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let local = dest.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(FileNameSanitizer.sanitizeName(name))")
            do {
                try FileManager.default.copyItem(at: original, to: local)
                let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                var task = TransferTask.new(kind: "upload", name: name, size: size, targetFolder: folderId)
                task.localPath = local.path
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.transferStore.saveAll([task] + self.transferStore.loadAll())
                    self.syncTasks()
                    self.showNotice("已加入 1 个上传任务")
                    self.tab = 1
                    self.page = .main
                    self.pumpTransfers()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failure = "无法读取原文件，请重新选择"
                }
            }
        }
    }

    func queueUpload(urls: [URL]) {
        for url in urls {
            queueUpload(localURL: url, folderId: folderId)
        }
    }

    func queueDownload(file: JSON, notice: Bool = true) {
        var task = TransferTask.new(kind: "download", name: file["name"].string, size: file["size"].int64, targetFolder: nil)
        task.fileId = file["id"].int
        transferStore.saveAll([task] + transferStore.loadAll())
        syncTasks()
        if notice { showNotice("已加入下载队列") }
        pumpTransfers()
    }

    /// 并发泵：最多 2 个活动任务（对标安卓并发 2）
    func pumpTransfers() {
        var running = runners.values.count
        guard running < 2 else { return }
        for t in transferStore.loadAll() where t.state == .queued && runners[t.id] == nil {
            if running >= 2 { break }
            if wifiOnly && pathIsExpensive {
                transferStore.update(t.id) { $0.error = "等待 Wi-Fi，请连接后恢复" }
                continue
            }
            startRunner(t)
            running += 1
        }
        syncTasks()
    }

    private func startRunner(_ task: TransferTask) {
        let id = task.id
        rates[id] = TransferRate()
        let t = Task { [weak self] in
            await self?.executeTask(task)
        }
        runners[id] = t
    }

    private func executeTask(_ base: TransferTask) async {
        let id = base.id
        transferStore.update(id) { $0.state = .running; $0.error = "" }
        syncTasks()

        var finalState: TransferState = .done
        var finalError = ""
        var localPath = base.localPath

        if base.kind == "upload" {
            do {
                _ = try await uploadManager.upload(
                    localPath: URL(fileURLWithPath: base.localPath),
                    displayName: base.name,
                    folderId: base.targetFolder,
                    jobId: id
                )
            } catch {
                let api = error as? ApiError
                if api?.code == "paused" {
                    finalState = .paused
                } else if api?.code == "cancelled" {
                    finalState = .cancelled
                } else {
                    finalState = .failed
                    finalError = api?.message ?? "连接中断，请重试"
                }
            }
        } else {
            do {
                let result = try await downloadManager.start(
                    fileId: base.fileId,
                    name: base.name,
                    size: base.size,
                    jobId: id
                )
                if result.cancelled {
                    finalState = pendingStop[id] == "cancel" ? .cancelled : .paused
                } else if result.ok {
                    localPath = result.path.path
                } else {
                    finalState = .failed
                    finalError = result.message ?? "下载响应无效"
                }
            } catch {
                let api = error as? ApiError
                finalState = .failed
                finalError = api?.message ?? "连接中断，请重试"
            }
        }

        pendingStop.removeValue(forKey: id)
        transferStore.update(id) {
            $0.state = finalState
            $0.error = finalError
            $0.localPath = localPath
            if finalState == .done { $0.done = $0.size; $0.speed = 0 }
        }
        rates.removeValue(forKey: id)
        runners.removeValue(forKey: id)
        syncTasks()
        pumpTransfers()
    }

    func pauseTask(_ task: TransferTask) {
        pendingStop[task.id] = "pause"
        if task.kind == "upload" {
            uploadManager.pause(jobId: task.id)
        } else {
            downloadManager.cancel(jobId: task.id)
        }
    }

    func resumeTask(_ task: TransferTask) {
        guard runners[task.id] == nil else { return }
        transferStore.update(task.id) { $0.state = .queued; $0.error = "" }
        syncTasks()
        pumpTransfers()
    }

    func cancelTask(_ task: TransferTask) {
        pendingStop[task.id] = "cancel"
        if task.kind == "upload" {
            uploadManager.cancel(jobId: task.id) // 内部会 abandon 服务端会话
        } else {
            downloadManager.cancelAndDiscard(jobId: task.id) // 删除 .part
        }
    }

    func pauseAllTasks() {
        for t in transferStore.loadAll() where t.isActive && runners[t.id] != nil {
            pauseTask(t)
        }
    }

    func clearFinishedTasks() {
        transferStore.removeWhere { $0.state == .done || $0.state == .cancelled }
        syncTasks()
    }
}
