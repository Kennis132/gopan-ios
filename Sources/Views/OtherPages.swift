import SwiftUI
import PhotosUI

// MARK: - 回收站（对标安卓 RecyclePage）

struct RecycleView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    private var recycled: [(item: JSON, isDir: Bool)] {
        state.recycleFolders.map { ($0, true) } + state.recycleFiles.map { ($0, false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "回收站", subtitle: "误删的文件，也能再找回来") {
                Button {
                    state.page = .main
                    Task { await state.load() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(t.onSurface)
                }
            }
            if recycled.isEmpty && !state.loadingFiles {
                EmptyStateView(icon: "arrow.uturn.backward.circle", title: "回收站很干净", detail: "删除的文件会保留在这里，可恢复或彻底删除。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(recycled.enumerated()), id: \.element.item.idValue) { _, entry in
                            RecycleRow(item: entry.item, isDirectory: entry.isDir)
                            Rectangle()
                                .fill(t.outlineVariant.opacity(0.65))
                                .frame(height: 1)
                                .padding(.leading, 64)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .background(t.background)
    }
}

struct RecycleRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let item: JSON
    let isDirectory: Bool

    var body: some View {
        Button {
            state.fileActions = FileActionContext(item: item, isDirectory: isDirectory, recycle: true)
        } label: {
            HStack(spacing: 0) {
                FileVisual(client: state.client, item: item, isDirectory: isDirectory, size: 48)
                    .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item["name"].string)
                        .font(.gBodyLarge.weight(.medium))
                        .foregroundStyle(t.onSurface)
                        .lineLimit(1)
                    Text(isDirectory ? "文件夹" : ByteFmt.bytes(item["size"].int64) + "  ·  " + ByteFmt.shortDate(item["deleted_at"].string))
                        .font(.gLabelSmall)
                        .foregroundStyle(t.onSurfaceVariant)
                }
                .padding(.leading, 14)
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分享页（对标安卓 SharesPage）

struct SharesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "我的分享", subtitle: "链接权限与主页展示分别管理") {
                if state.page == .main {
                    Button {
                        state.showShareViewer = true
                    } label: {
                        Image(systemName: "eye").frame(width: 36, height: 36)
                    }
                } else {
                    Button {
                        state.page = .main
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(t.onSurface)
                    }
                }
            }
            .font(.system(size: 17))
            .foregroundStyle(t.onSurfaceVariant)

            if state.shares.isEmpty {
                EmptyStateView(icon: "link", title: "还没有分享链接", detail: "在文件的更多操作里，创建你的第一份分享。")
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(state.shares, id: \.idValue) { share in
                            ShareCard(share: share)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(t.background)
    }
}

struct ShareCard: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let share: JSON
    @State private var menuOpen = false
    @State private var copied = false

    private var status: (text: String, color: Color) {
        let expiresAt = share["expires_at"].int64Value
        let maxHits = share["max_hits"].int64Value
        let hits = share["hits"].int64
        if expiresAt > 0 && expiresAt < Date().timeIntervalSince1970 * 1000 {
            return ("已过期", t.error)
        }
        if maxHits > 0 && Int64(hits) >= maxHits {
            return ("次数已用完", t.error)
        }
        return ("链接有效", t.success)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(t.primaryContainer)
                        Image(systemName: "link")
                            .font(.system(size: 17))
                            .foregroundStyle(t.primary)
                    }
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(share["file_name"].string)
                            .font(.gTitleSmall)
                            .foregroundStyle(t.onSurface)
                            .lineLimit(2)
                        Text(status.text)
                            .font(.gLabelSmall)
                            .foregroundStyle(status.color)
                    }
                    Spacer()
                    Menu {
                        Button(share["visibility"].string == "public" ? "从公开主页隐藏" : "在公开主页展示") {
                            Task { await state.toggleShareVisibility(share) }
                        }
                        Button("撤销分享", role: .destructive) {
                            state.confirm = ConfirmConfig(title: "撤销分享？", detail: "已有链接将无法继续访问。", danger: true) {
                                Task { await state.revokeShare(share) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(t.onSurfaceVariant)
                            .frame(width: 32, height: 32)
                    }
                }
                Spacer().frame(height: 16)
                HStack(spacing: 14) {
                    Label(share["needs_password"].bool ? "密码保护" : "无需密码",
                          systemImage: share["needs_password"].bool ? "lock" : "lock.open")
                    Label("\(share["hits"].int) / \(share["max_hits"].int64Value == 0 ? "不限" : share["max_hits"].string) 次",
                          systemImage: "eye")
                }
                .font(.gLabelSmall)
                .foregroundStyle(t.onSurfaceVariant)
                Spacer().frame(height: 10)
                Text(share["expires_at"].int64Value > 0 ? "到期：\(ByteFmt.dateTime(share["expires_at"].int64Value))" : "长期有效")
                    .font(.gBodySmall)
                    .foregroundStyle(t.onSurfaceVariant)
                Spacer().frame(height: 14)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = "\(state.client.baseURL)/s/\(share["token"].string)"
                        copied = true
                        state.showNotice("已复制")
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Text(copied ? "已复制" : "复制链接")
                            .font(.gBodyMedium)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(t.outlineVariant, lineWidth: 1)
                    }
                    ShareLink(item: "\(state.client.baseURL)/s/\(share["token"].string)") {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.gBodyMedium)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .foregroundStyle(t.primary)
                    .background(t.primaryContainer)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 留言板（对标安卓 CommunityPage）

struct CommunityView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "留言板", subtitle: "写下想法，看看大家的近况") {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                }
            }
            ScrollView {
                VStack(spacing: 16) {
                    if !state.site["announcement"].string.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 9) {
                                Image(systemName: "megaphone")
                                    .font(.system(size: 15))
                                    .foregroundStyle(t.primary)
                                Text("站点公告").font(.gTitleSmall).foregroundStyle(t.primary)
                            }
                            Text(state.site["announcement"].string)
                                .font(.gBodyMedium)
                        }
                        .padding(20)
                        .background(t.primaryContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    Button {
                        state.showMessageComposer = true
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(client: state.client, name: state.displayName, avatarURL: state.user?["avatar_url"].stringValue, size: 40)
                            Text("今天有什么想分享的？")
                                .font(.gBodyMedium)
                                .foregroundStyle(t.onSurfaceVariant)
                            Spacer()
                            Text("写留言")
                                .font(.gBodyMedium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(t.primary)
                                .background(t.primaryContainer)
                                .clipShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(state.site["guestbookOpen"].bool == false && state.siteLoaded)

                    if state.messages.isEmpty && !state.loadingFiles {
                        EmptyStateView(icon: "bubble.left.and.bubble.right", title: "还没有留言", detail: "写下第一条留言，和大家打个招呼。")
                    }
                    ForEach(state.messages, id: \.idValue) { m in
                        MessageCard(m: m)
                    }
                }
                .padding(20)
            }
        }
        .background(t.background)
    }
}

struct MessageCard: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let m: JSON

    private var authorName: String {
        let dn = m["display_name"].string
        return dn.isEmpty ? m["author"].string : dn
    }

    private var canDelete: Bool {
        let uid = m["user_id"].int64Value
        let myId = state.user?["id"].int64Value ?? -1
        return (uid > 0 && uid == myId) || state.user?["role"].string == "admin"
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    AvatarView(client: state.client, name: authorName, avatarURL: m["avatar_url"].stringValue, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(authorName).font(.gTitleSmall).foregroundStyle(t.onSurface)
                        Text(String(m["created_at"].string.replacingOccurrences(of: "T", with: " ").prefix(16)))
                            .font(.gLabelSmall)
                            .foregroundStyle(t.onSurfaceVariant)
                    }
                    Spacer()
                    if canDelete {
                        Button {
                            state.confirm = ConfirmConfig(title: "删除留言？", detail: "删除后无法恢复。", danger: true) {
                                Task { await state.deleteMessage(m) }
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                                .foregroundStyle(t.onSurfaceVariant)
                                .frame(width: 32, height: 32)
                        }
                    }
                }
                Text(m["message"].string)
                    .font(.gBodyLarge)
                    .foregroundStyle(t.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 我的（对标安卓 ProfilePage）

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var avatarPicker: PhotosPickerItem?

    private var used: Int64 { state.user?["used_bytes"].int64 ?? 0 }
    private var quota: Int64 { max(1, state.user?["quota_bytes"].int64 ?? 1) }
    private var fraction: Double { min(1, max(0, Double(used) / Double(quota))) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "我的空间", subtitle: "每一次登录，都回到熟悉的地方") {
                Button {
                    state.page = .settings
                } label: {
                    Image(systemName: "gearshape").frame(width: 36, height: 36)
                }
            }
            ScrollView {
                VStack(spacing: 16) {
                    profileCard
                    storageCard
                    menuGroup
                    logoutButton
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(t.background)
    }

    private var profileCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 18) {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(client: state.client, name: state.displayName, avatarURL: state.user?["avatar_url"].stringValue, size: 80)
                        ZStack {
                            Circle().fill(t.primary)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(t.onPrimary)
                        }
                        .frame(width: 25, height: 25)
                        .overlay { Circle().strokeBorder(t.surface, lineWidth: 2) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(state.displayName)
                            .font(.gHeadlineMedium)
                            .foregroundStyle(t.onSurface)
                        Spacer().frame(height: 5)
                        Text("@\(state.user?["username"].string ?? "")")
                            .font(.gBodyMedium)
                            .foregroundStyle(t.onSurfaceVariant)
                        Spacer().frame(height: 9)
                        Text(state.user?["role"].string == "admin" ? "管理员" : "云盘成员")
                            .font(.gLabelSmall)
                            .foregroundStyle(t.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(t.primaryContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Spacer()
                }
                Text(state.user?["bio"].string.isEmpty == false ? state.user!["bio"].string : "收藏日常，也收藏灵感。")
                    .font(.gBodyMedium)
                    .foregroundStyle(t.onSurfaceVariant)
                HStack(spacing: 12) {
                    Button {
                        state.showEditProfile = true
                    } label: {
                        Label("编辑资料", systemImage: "pencil")
                            .font(.gBodyMedium)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(t.outlineVariant, lineWidth: 1)
                    }
                    PhotosPicker(selection: $avatarPicker, matching: .images) {
                        Label("更换头像", systemImage: "photo")
                            .font(.gBodyMedium)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .foregroundStyle(t.primary)
                    .background(t.primaryContainer)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: avatarPicker) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await state.uploadAvatarImage(image)
                }
                avatarPicker = nil
            }
        }
    }

    private var storageCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitleView(title: "存储空间")
                Spacer().frame(height: 16)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(ByteFmt.bytes(used))
                        .font(.gHeadlineMedium)
                        .foregroundStyle(t.primary)
                    Text(" / \(ByteFmt.bytes(quota))")
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onSurfaceVariant)
                }
                Spacer().frame(height: 15)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(t.primaryContainer)
                        Capsule().fill(t.primary).frame(width: max(0, geo.size.width * fraction))
                    }
                }
                .frame(height: 7)
                Spacer().frame(height: 10)
                Text("剩余 \(ByteFmt.bytes(max(quota - used, 0)))")
                    .font(.gLabelSmall)
                    .foregroundStyle(t.onSurfaceVariant)
            }
        }
    }

    private var menuGroup: some View {
        VStack(spacing: 0) {
            SettingRow(icon: "arrow.uturn.backward.circle", title: "回收站", subtitle: "恢复文件与文件夹") {
                state.page = .recycle
                Task { await state.load() }
            }
            Divider().foregroundStyle(t.outlineVariant)
            SettingRow(icon: "lock", title: "修改密码", subtitle: "密码修改后其他设备会退出") {
                state.showPasswordSheet = true
            }
            Divider().foregroundStyle(t.outlineVariant)
            SettingRow(icon: "ipad.and.iphone", title: "登录设备", subtitle: "查看会话并退出其他设备") {
                state.showSessionSheet = true
            }
        }
        .padding(.horizontal, 16)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var logoutButton: some View {
        Button {
            state.confirm = ConfirmConfig(title: "退出当前账户？", detail: "传输任务会暂停并保留断点。") {
                Task { await state.logout() }
            }
        } label: {
            Label("退出当前账户", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.gBodyLarge)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .foregroundStyle(t.error)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(t.outlineVariant, lineWidth: 1)
        }
    }
}
