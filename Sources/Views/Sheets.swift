import SwiftUI

// MARK: - 文件操作弹层（对标安卓 FileActions）

struct FileActionsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let ctx: FileActionContext

    private var item: JSON { ctx.item }

    private var subtitle: String {
        if ctx.isDirectory { return "文件夹" }
        let kind = FileKind.kind(name: item["name"].string)
        return "\(kind.label) · \(ByteFmt.bytes(item["size"].int64))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                FileVisual(client: state.client, item: item, isDirectory: ctx.isDirectory, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item["name"].string).font(.gTitleMedium).foregroundStyle(t.onSurface).lineLimit(1)
                    Text(subtitle).font(.gBodySmall).foregroundStyle(t.onSurfaceVariant)
                }
                Spacer()
            }
            .padding(.bottom, 12)
            Divider().foregroundStyle(t.outlineVariant)
            if ctx.recycle {
                SettingRow(icon: "arrow.uturn.backward.circle.fill", title: "恢复到云盘") {
                    state.fileActions = nil
                    Task { await state.restoreRecycle(item, isFolder: ctx.isDirectory) }
                }
                SettingRow(icon: "xmark.octagon.fill", title: "永久删除", subtitle: "此操作无法撤销", iconColor: t.primary) {
                    state.fileActions = nil
                    state.confirm = ConfirmConfig(title: "永久删除？", detail: "此操作无法撤销。", danger: true) {
                        Task { await state.purgeRecycle(item, isFolder: ctx.isDirectory) }
                    }
                }
            } else {
                if !ctx.isDirectory {
                    SettingRow(icon: "eye", title: "预览") {
                        let file = item
                        state.fileActions = nil
                        state.previewFile = file
                    }
                    SettingRow(icon: "arrow.down.circle", title: "下载到本机") {
                        let file = item
                        state.fileActions = nil
                        state.queueDownload(file: file)
                    }
                    SettingRow(icon: "link", title: "创建分享链接") {
                        let file = item
                        state.fileActions = nil
                        state.shareComposer = ShareComposerContext(file: file)
                    }
                }
                SettingRow(icon: "pencil", title: "重命名") {
                    let it = item
                    state.fileActions = nil
                    state.nameDialog = NameDialogConfig(title: "重命名", initial: it["name"].string, item: it, isFolder: ctx.isDirectory)
                }
                SettingRow(icon: "arrow.uturn.forward.folder", title: "移动到…") {
                    let it = item
                    state.fileActions = nil
                    state.moveChooser = MoveConfig(
                        title: "移动到",
                        items: [it],
                        isFolders: [ctx.isDirectory],
                        excludedFolderIds: ctx.isDirectory ? [it["id"].int] : []
                    )
                }
                SettingRow(icon: "trash", title: "移入回收站") {
                    let it = item
                    let isDir = ctx.isDirectory
                    state.fileActions = nil
                    state.confirm = ConfirmConfig(
                        title: "移入回收站？",
                        detail: isDir ? "文件夹及内容将一起移入回收站。" : "所选文件可在回收站恢复。",
                        danger: true
                    ) {
                        Task { await state.moveToRecycle(it, isFolder: isDir) }
                    }
                }
            }
            Spacer().frame(height: 24)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 重命名 / 新建文件夹（对标安卓 NameDialog）

struct NameDialogSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let config: NameDialogConfig
    @State private var value = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(config.title).font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            GField(label: "名称", placeholder: "名称", text: $value)
            HStack {
                Spacer()
                Button("取消") { state.nameDialog = nil }
                    .font(.gBodyLarge)
                    .foregroundStyle(t.primary)
                Spacer().frame(width: 12)
                Button {
                    busy = true
                    let name = value.trimmingCharacters(in: .whitespaces)
                    let item = config.item
                    let isFolder = config.isFolder
                    state.nameDialog = nil
                    Task {
                        if let item {
                            await state.rename(item, isFolder: isFolder, to: name)
                        } else {
                            await state.mkdir(name)
                        }
                    }
                } label: {
                    Text("保存").font(.gBodyLarge.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .foregroundStyle(t.onPrimary)
                .background(t.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.height(220)])
        .onAppear { value = config.initial }
    }
}

// MARK: - 移动选择器（对标安卓 MoveChooser）

struct MoveChooserSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let config: MoveConfig
    @State private var target: Int?
    @State private var folders: [JSON] = []
    @State private var crumbs: [JSON] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(config.title).font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            Spacer().frame(height: 14)
            HStack(spacing: 4) {
                Button {
                    let parentId = crumbs.count >= 2 ? crumbs[crumbs.count - 2]["id"].intValue : nil
                    target = parentId
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15))
                        .foregroundStyle(t.onSurfaceVariant)
                        .frame(width: 32, height: 32)
                }
                .disabled(target == nil)
                Text(crumbs.last?["name"].string.isEmpty == false ? crumbs.last!["name"].string : "根目录")
                    .font(.gTitleMedium)
                    .foregroundStyle(t.onSurface)
            }
            Spacer().frame(height: 10)
            ScrollView {
                VStack(spacing: 0) {
                    if folders.isEmpty {
                        Text("这里没有子文件夹")
                            .font(.gBodyMedium)
                            .foregroundStyle(t.onSurfaceVariant)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(folders, id: \.idValue) { folder in
                        Button {
                            target = folder["id"].intValue
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(hex: 0xCD9A40))
                                Text(folder["name"].string)
                                    .font(.gBodyLarge)
                                    .foregroundStyle(t.onSurface)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
            Spacer().frame(height: 18)
            Button {
                busy = true
                let t2 = target
                let cfg = config
                state.moveChooser = nil
                Task {
                    if cfg.items.count == 1 {
                        await state.move(cfg.items[0], isFolder: cfg.isFolders[0], to: t2)
                    } else {
                        await state.batchMoveTo(t2, items: cfg.items, isFolders: cfg.isFolders)
                    }
                }
            } label: {
                Text(busy ? "正在移动…" : "移动到此处")
                    .font(.gBodyLarge.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .foregroundStyle(t.onPrimary)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(busy)
            Spacer().frame(height: 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .task(id: target) {
            await loadFolders()
        }
    }

    private func loadFolders() async {
        do {
            let r = try await state.client.listFiles(folderId: target)
            folders = r["folders"].rows.filter { !config.excludedFolderIds.contains($0["id"].int) }
            crumbs = r["breadcrumb"].rows
        } catch {
            state.handle(error)
        }
    }
}

// MARK: - 创建分享（对标安卓 ShareComposer）

struct ShareComposerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let ctx: ShareComposerContext
    @State private var days = ""
    @State private var password = ""
    @State private var hits = ""
    @State private var publicShow = false
    @State private var busy = false
    @State private var localError = ""
    @State private var result: String?

    private var limits: JSON { state.limits }
    private var shareMaxDays: Int { limits["shareMaxDays"].int == 0 ? 365 : limits["shareMaxDays"].int }
    private var shareDefaultDays: Int { limits["shareDefaultDays"].int == 0 ? 7 : limits["shareDefaultDays"].int }
    private var minPasswordLen: Int { limits["shareMinPasswordLength"].int == 0 ? 4 : limits["shareMinPasswordLength"].int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(result == nil ? "创建分享" : "分享已准备好")
                    .font(.gHeadlineMedium)
                    .foregroundStyle(t.onSurface)
                Text(ctx.file["name"].string)
                    .font(.gBodyMedium)
                    .foregroundStyle(t.onSurfaceVariant)
                    .lineLimit(1)
                Spacer().frame(height: 18)
                if let result {
                    resultView(result)
                } else {
                    formView
                }
                Spacer().frame(height: 28)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .onAppear {
            if days.isEmpty { days = String(shareDefaultDays) }
        }
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            GField(label: "有效天数", placeholder: "7", text: $days, keyboard: .numberPad, supporting: "留空为长期，最多 \(shareMaxDays) 天")
            GField(label: "访问密码（可选）", placeholder: "", text: $password)
            GField(label: "最大访问次数", placeholder: "", text: $hits, keyboard: .numberPad,
                   supporting: limits["shareAllowUnlimitedHits"].boolValue == false ? "当前站点要求填写访问次数" : "留空为不限次数")
            Toggle(isOn: $publicShow) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("在我的公开主页展示").font(.gBodyLarge).foregroundStyle(t.onSurface)
                    Text("关闭只隐藏主页展示，链接仍可访问。").font(.gBodySmall).foregroundStyle(t.onSurfaceVariant)
                }
            }
            .tint(t.primary)
            if !localError.isEmpty {
                Text(localError).font(.gBodyMedium).foregroundStyle(t.error)
            }
            if let failure = state.failure, !failure.isEmpty {
                Text(failure).font(.gBodyMedium).foregroundStyle(t.error)
            }
            Button {
                Task { await submit() }
            } label: {
                Text(busy ? "正在创建…" : "创建分享链接")
                    .font(.gBodyLarge.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .foregroundStyle(t.onPrimary)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(busy)
        }
    }

    private func resultView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Panel {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(t.primary)
                    Text(text)
                        .font(.gBodyLarge)
                        .foregroundStyle(t.onSurface)
                        .textSelection(.enabled)
                }
            }
            Spacer().frame(height: 18)
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = text
                    state.showNotice("已复制")
                } label: {
                    Text("复制")
                        .font(.gBodyLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(t.outlineVariant, lineWidth: 1)
                }
                ShareLink(item: text) {
                    Text("发送分享")
                        .font(.gBodyLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .foregroundStyle(t.onPrimary)
                .background(t.primary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func submit() async {
        localError = ""
        var d: Int?
        var h: Int?
        if !days.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let dv = Int(days), dv > 0, dv <= shareMaxDays else {
                localError = "请填写有效天数"
                return
            }
            d = dv
        }
        if !hits.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let hv = Int(hits), hv > 0 else {
                localError = "次数必须为正整数"
                return
            }
            h = hv
        }
        if !password.isEmpty && password.count < minPasswordLen {
            localError = "密码长度不符合站点要求"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let r = try await state.createShare(
                fileId: ctx.file["id"].int,
                expiresIn: d.map { $0 * 86400 },
                password: password,
                maxHits: h,
                visibility: publicShow ? "public" : "private"
            )
            var text = "\(state.client.baseURL)\(r["url"].string)"
            if !password.isEmpty {
                text += "\n访问密码：\(password)"
            }
            result = text
        } catch {
            state.handle(error)
        }
    }
}

// MARK: - 查看他人分享（对标安卓 ShareViewer）

struct ShareViewerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var link = ""
    @State private var meta: JSON?
    @State private var password = ""
    @State private var ticket: String?
    @State private var busy = false
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var localError = ""
    @State private var savedPath: String?
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("查看分享").font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            Text("粘贴别人发的分享链接，查看内容后一键取回。")
                .font(.gBodyMedium)
                .foregroundStyle(t.onSurfaceVariant)
            Spacer().frame(height: 20)
            HStack(spacing: 0) {
                TextField("https://…/s/…", text: $link)
                    .font(.gBodyLarge)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    if let s = UIPasteboard.general.string, !s.isEmpty {
                        link = s
                        Task { await load() }
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(t.onSurfaceVariant)
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(t.outlineVariant, lineWidth: 1)
            )
            if !localError.isEmpty {
                Spacer().frame(height: 10)
                Text(localError).font(.gBodyMedium).foregroundStyle(t.error)
            }
            Spacer().frame(height: 14)
            Button {
                Task { await load() }
            } label: {
                Text(busy && meta == nil ? "正在查看…" : "查看分享")
                    .font(.gBodyLarge.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .foregroundStyle(t.onPrimary)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(link.isEmpty || busy)

            if let meta {
                metaPanel(meta)
            }
            Spacer().frame(height: 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .sheet(item: $quickLookURL) { url in
            QuickLookView(url: url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func metaPanel(_ meta: JSON) -> some View {
        Spacer().frame(height: 20)
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    let kind = FileKind.kind(name: meta["name"].string)
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(kind.tint.faint)
                        Image(systemName: kind.icon)
                            .font(.system(size: 20))
                            .foregroundStyle(kind.tint)
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meta["name"].string)
                            .font(.gTitleSmall)
                            .foregroundStyle(t.onSurface)
                            .lineLimit(2)
                        Text("来自 @\(meta["owner"].string)")
                            .font(.gLabelSmall)
                            .foregroundStyle(t.onSurfaceVariant)
                    }
                    Spacer()
                }
                Spacer().frame(height: 12)
                Text(infoText(meta))
                    .font(.gLabelSmall)
                    .foregroundStyle(t.onSurfaceVariant)
                Spacer().frame(height: 10)
                statusLine(meta)
                if meta["needsPassword"].boolValue && ticket == nil {
                    Spacer().frame(height: 12)
                    GField(label: "分享密码", placeholder: "", text: $password, secure: true)
                }
                if downloading {
                    Spacer().frame(height: 12)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(t.primaryContainer)
                            Capsule().fill(t.primary).frame(width: max(0, geo.size.width * progress))
                        }
                    }
                    .frame(height: 6)
                }
                Spacer().frame(height: 14)
                downloadButton(meta)
                if let savedPath {
                    Spacer().frame(height: 10)
                    Button {
                        quickLookURL = URL(fileURLWithPath: savedPath)
                    } label: {
                        Text("打开文件")
                            .font(.gBodyLarge)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(t.outlineVariant, lineWidth: 1)
                    }
                }
            }
        }
    }

    private func infoText(_ meta: JSON) -> String {
        var info = "\(ByteFmt.bytes(meta["size"].int64)) · 已下载 \(meta["hits"].int) 次"
        if meta["expiresAt"].int64Value > 0 {
            info += " · 到期 \(ByteFmt.dateTime(meta["expiresAt"].int64Value))"
        }
        return info
    }

    @ViewBuilder
    private func statusLine(_ meta: JSON) -> some View {
        if meta["available"].boolValue == false {
            let reason = meta["reason"].string
            Text(reason.isEmpty ? "链接不可用" : reason)
                .font(.gLabelSmall)
                .foregroundStyle(t.error)
        } else if meta["needsPassword"].boolValue && ticket == nil {
            Text("需要访问密码").font(.gLabelSmall).foregroundStyle(t.onSurfaceVariant)
        } else {
            Text("可以下载").font(.gLabelSmall).foregroundStyle(t.success)
        }
    }

    private func downloadButton(_ meta: JSON) -> some View {
        let needsPassword = meta["needsPassword"].boolValue && ticket == nil
        let label = downloading ? "正在下载…"
            : savedPath != nil ? "重新下载"
            : needsPassword ? (password.isEmpty ? "先填写访问密码" : "解锁并下载")
            : "下载到本机"
        return Button {
            Task { await download(meta) }
        } label: {
            Text(label)
                .font(.gBodyLarge.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
        .foregroundStyle(t.onPrimary)
        .background(t.primary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(downloading || (needsPassword && password.isEmpty))
    }

    private func token() -> String? {
        if let range = link.range(of: "[0-9a-fA-F]{32}", options: .regularExpression) {
            return String(link[range]).lowercased()
        }
        return nil
    }

    private func load() async {
        localError = ""
        guard let t = token() else {
            localError = "没有找到 32 位分享码，请粘贴完整分享链接"
            return
        }
        busy = true
        defer { busy = false }
        do {
            meta = try await state.client.publicShare(token: t)
            ticket = nil
            savedPath = nil
        } catch {
            localError = (error as? ApiError)?.message ?? "连接中断，请重试"
        }
    }

    private func download(_ meta: JSON) async {
        localError = ""
        guard let t = token() else { return }
        downloading = true
        progress = 0
        defer { downloading = false }
        do {
            var currentTicket = ticket
            if currentTicket == nil {
                let r = try await state.client.unlockShare(token: t, password: password.isEmpty ? nil : password)
                currentTicket = r["ticket"].string
                ticket = currentTicket
            }
            guard let tk = currentTicket else { return }
            let request = try state.client.makeShareFileRequest(token: t, ticket: tk)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                ticket = nil
                localError = "请先验证下载权限（凭证缺失或过期）"
                return
            }
            let clean = FileNameSanitizer.sanitizeName(meta["name"].string)
            let dir = AppState.documentsDirectory
            let dest = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(clean)")
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let handle = try FileHandle(forWritingTo: dest.createIfMissing())
            let total = http.expectedContentLength
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { progress = Double(received) / Double(total) }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            try? handle.close()
            savedPath = dest.path
            state.showNotice("分享文件已保存到本机")
        } catch {
            ticket = nil
            localError = (error as? ApiError)?.message ?? "连接中断，请重试"
        }
    }
}

private extension URL {
    func createIfMissing() -> URL {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        return self
    }
}

// MARK: - 修改密码（对标安卓 PasswordDialog）

struct PasswordSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var old = ""
    @State private var next = ""
    @State private var repeatPw = ""
    @State private var busy = false

    private var minLength: Int { state.limits["passwordMinLength"].int == 0 ? 8 : state.limits["passwordMinLength"].int }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("修改密码").font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            Text("修改成功后，其他设备的登录会话将退出。")
                .font(.gBodyMedium)
                .foregroundStyle(t.onSurfaceVariant)
            Spacer().frame(height: 20)
            GField(label: "当前密码", placeholder: "", text: $old, secure: true)
            Spacer().frame(height: 14)
            GField(label: "新密码", placeholder: "", text: $next, secure: true)
            Spacer().frame(height: 14)
            GField(label: "再次输入新密码", placeholder: "", text: $repeatPw, secure: true)
            if !repeatPw.isEmpty && repeatPw != next {
                Spacer().frame(height: 10)
                Text("两次密码不一致").font(.gBodyMedium).foregroundStyle(t.error)
            }
            if let f = state.failure, !f.isEmpty {
                Spacer().frame(height: 10)
                Text(f).font(.gBodyMedium).foregroundStyle(t.error)
            }
            Spacer().frame(height: 18)
            Button {
                Task {
                    busy = true
                    let ok = await state.changePassword(old: old, next: next)
                    busy = false
                    if ok { state.showPasswordSheet = false }
                }
            } label: {
                Text("更新密码")
                    .font(.gBodyLarge.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .foregroundStyle(t.onPrimary)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(busy || old.isEmpty || next.count < minLength || repeatPw != next)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }
}

// MARK: - 登录设备（对标安卓 SessionSheet）

struct SessionSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var sessions: [JSON] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("登录设备").font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            Spacer().frame(height: 18)
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sessions, id: \.idValue) { s in
                            HStack(spacing: 14) {
                                Image(systemName: "laptopcomputer.and.iphone")
                                    .font(.system(size: 17))
                                    .foregroundStyle(t.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s["current"].boolValue ? "当前设备" : "其他登录会话")
                                        .font(.gBodyLarge)
                                        .foregroundStyle(t.onSurface)
                                    Text("登录于 \(s["created_at"].string)")
                                        .font(.gBodyMedium)
                                        .foregroundStyle(t.onSurfaceVariant)
                                }
                                Spacer()
                                if s["current"].boolValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundStyle(t.primary)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            Spacer().frame(height: 18)
            Button {
                Task {
                    await state.revokeSessions()
                    await load()
                }
            } label: {
                Text("退出其他所有设备")
                    .font(.gBodyLarge)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(t.outlineVariant, lineWidth: 1)
            }
            Spacer().frame(height: 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .task {
            await load()
        }
    }

    private func load() async {
        do {
            let r = try await state.client.sessions()
            sessions = r["sessions"].rows
        } catch {
            state.handle(error)
        }
        loading = false
    }
}

// MARK: - 编辑资料（对标安卓 EditProfile）

struct EditProfileSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var displayName = ""
    @State private var bio = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("编辑资料").font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            Spacer().frame(height: 22)
            HStack {
                Spacer()
                AvatarView(client: state.client, name: state.displayName, avatarURL: state.user?["avatar_url"].stringValue, size: 72)
                Spacer()
            }
            Spacer().frame(height: 22)
            GField(label: "昵称", placeholder: "", text: $displayName, supporting: "\(displayName.count)/24", limit: 24)
            Spacer().frame(height: 14)
            VStack(alignment: .leading, spacing: 6) {
                TextField("简介", text: $bio, axis: .vertical)
                    .font(.gBodyLarge)
                    .lineLimit(3...6)
                    .onChange(of: bio) { _, newValue in
                        if newValue.count > 200 { bio = String(newValue.prefix(200)) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(t.outlineVariant, lineWidth: 1)
                    )
                Text("\(bio.count)/200").font(.gLabelSmall).foregroundStyle(t.onSurfaceVariant)
            }
            if let f = state.failure, !f.isEmpty {
                Spacer().frame(height: 10)
                Text(f).font(.gBodyMedium).foregroundStyle(t.error)
            }
            Spacer().frame(height: 18)
            Button {
                Task {
                    busy = true
                    await state.saveProfile(displayName, bio: bio)
                    busy = false
                    state.showEditProfile = false
                }
            } label: {
                Text(busy ? "正在保存…" : "保存资料")
                    .font(.gBodyLarge.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .foregroundStyle(t.onPrimary)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(busy)
            Button("移除当前头像") {
                Task {
                    await state.removeAvatar()
                    state.showEditProfile = false
                }
            }
            .font(.gBodyLarge)
            .foregroundStyle(t.primary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .onAppear {
            displayName = state.user?["display_name"].string ?? ""
            bio = state.user?["bio"].string ?? ""
        }
    }
}

// MARK: - 写留言（对标安卓 MessageComposer）

struct MessageComposerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("写一条留言").font(.gHeadlineMedium).foregroundStyle(t.onSurface)
            Spacer().frame(height: 22)
            HStack(spacing: 12) {
                AvatarView(client: state.client, name: state.displayName, avatarURL: state.user?["avatar_url"].stringValue, size: 38)
                Text(state.displayName).font(.gTitleSmall).foregroundStyle(t.onSurface)
            }
            Spacer().frame(height: 18)
            TextField("记录今天的小事，或分享一个新发现…", text: $text, axis: .vertical)
                .font(.gBodyLarge)
                .lineLimit(5...8)
                .onChange(of: text) { _, newValue in
                    if newValue.count > 2000 { text = String(newValue.prefix(2000)) }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(t.outlineVariant, lineWidth: 1)
                )
            Text("\(text.count)/2000")
                .font(.gLabelSmall)
                .foregroundStyle(t.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer().frame(height: 14)
            Button {
                Task {
                    busy = true
                    await state.postMessage(text)
                    busy = false
                    state.showMessageComposer = false
                }
            } label: {
                Text(busy ? "正在发布…" : "发布留言")
                    .font(.gBodyLarge.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .foregroundStyle(t.onPrimary)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
    }
}

// MARK: - 他人公开主页（对标安卓 UserSheet）

struct UserSheetView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let username: String
    @State private var profile: JSON?
    @State private var shares: [JSON] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        AvatarView(client: state.client, name: profile?["display_name"].string ?? username, avatarURL: profile?["avatar_url"].stringValue, size: 72)
                        Text(profile?["display_name"].string.isEmpty == false ? profile!["display_name"].string : username)
                            .font(.gHeadlineMedium)
                            .foregroundStyle(t.onSurface)
                        Text("@\(username)").font(.gBodyMedium).foregroundStyle(t.onSurfaceVariant)
                        if !(profile?["bio"].string ?? "").isEmpty {
                            Text(profile!["bio"].string)
                                .font(.gBodyMedium)
                                .foregroundStyle(t.onSurfaceVariant)
                                .multilineTextAlignment(.center)
                        }
                    }
                    Spacer()
                }
                Spacer().frame(height: 22)
                SectionTitleView(title: "公开分享")
                Spacer().frame(height: 10)
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if shares.isEmpty {
                    Text("还没有公开分享")
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onSurfaceVariant)
                        .padding(.vertical, 16)
                } else {
                    ForEach(shares, id: \.idValue) { share in
                        SettingRow(icon: "link", title: share["file_name"].string) {
                            UIPasteboard.general.string = "\(state.client.baseURL)/s/\(share["token"].string)"
                            state.showNotice("已复制链接")
                        }
                    }
                }
                Spacer().frame(height: 24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(t.surface)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .task {
            await state.loadPublicUser(username)
            profile = state.publicProfile?["profile"]
            shares = state.publicProfile?["shares"].rows ?? []
            loading = false
        }
    }
}
