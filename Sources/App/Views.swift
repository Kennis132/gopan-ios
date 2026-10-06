import SwiftUI
import UniformTypeIdentifiers

@main
struct GopanApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if !state.bootstrapped {
                ProgressView()
            } else if state.loggedIn {
                DriveView()
            } else {
                LoginView()
            }
        }
        .task { await state.bootstrap() }
        .alert("提示", isPresented: .constant(state.alertMessage != nil)) {
            Button("好", role: .cancel) { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("服务器") {
                TextField("http://192.168.1.7:8787", text: $state.serverInput)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                let parsed = ServerConfig.parseServerURL(state.serverInput)
                if parsed.ok && parsed.needsAck {
                    Toggle("我确认使用明文 HTTP 的风险", isOn: $state.ackInsecure)
                }
            }
            Section(state.isRegisterMode ? "注册新账号" : "登录") {
                TextField("用户名", text: $state.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("密码", text: $state.password)
            }
            Button(state.isRegisterMode ? "注册并登录" : "登录") {
                Task { await state.submitLogin() }
            }
            Button(state.isRegisterMode ? "返回登录" : "没有账号？注册") {
                state.isRegisterMode.toggle()
            }
        }
        .navigationTitle("篝火云盘")
    }
}

struct DriveView: View {
    @EnvironmentObject var state: AppState
    @State private var showNewFolder = false
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                BreadcrumbRow()
                ForEach(state.folders, id: \.idValue) { folder in
                    Button {
                        state.openFolder(folder)
                    } label: {
                        Label(folder["name"].string, systemImage: "folder.fill")
                            .foregroundStyle(.primary)
                    }
                    .contextMenu {
                        Button("重命名") { state.pendingRename = folder; state.isRenamingFolder = true }
                        Button("删除", role: .destructive) { Task { await state.delete(folder, isFolder: true) } }
                    }
                }
                ForEach(state.files, id: \.idValue) { file in
                    FileRow(file: file)
                        .contextMenu {
                            Button("下载") { state.download(file) }
                            Button("重命名") { state.pendingRename = file; state.isRenamingFolder = false }
                            Button("删除", role: .destructive) { Task { await state.delete(file, isFolder: false) } }
                        }
                }
                if !state.transfers.isEmpty {
                    Section("传输中") {
                        ForEach(state.transfers) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name).font(.footnote)
                                ProgressView(value: row.total > 0 ? Double(row.sent) / Double(row.total) : 0)
                                Text("\(row.phase) · \(row.sent)/\(row.total) 字节")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .refreshable { await state.refresh() }
            .navigationTitle(state.siteName)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("新建文件夹") { showNewFolder = true }
                        Button("上传文件") { showImporter = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    Menu {
                        Button("退出登录", role: .destructive) { Task { await state.logout() } }
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("名称", text: $state.newFolderName)
                Button("创建") { Task { await state.mkdir(state.newFolderName) }; state.newFolderName = "" }
                Button("取消", role: .cancel) { state.newFolderName = "" }
            }
            .alert("重命名", isPresented: renameBinding) {
                TextField("名称", text: $state.renameText)
                Button("确定") {
                    if let item = state.pendingRename {
                        Task { await state.rename(item, isFolder: state.isRenamingFolder, to: state.renameText) }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case let .success(urls) = result {
                    state.uploadFiles(urls: urls)
                }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { state.pendingRename != nil }, set: { if !$0 { state.pendingRename = nil } })
    }
}

struct BreadcrumbRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("首页") { state.openCrumb(nil) }
                ForEach(state.crumbs, id: \.idValue) { crumb in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(crumb["name"].string) {
                        state.openCrumb(crumb)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline)
        }
        .listRowBackground(Color.clear)
    }
}

struct FileRow: View {
    @EnvironmentObject var state: AppState
    let file: JSON

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(file["name"].string)
                    .lineLimit(1)
                Text(ByteFormatter.format(file["size"].int64))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.download(file)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    var iconName: String {
        let mime = file["mime"].string
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "video.fill" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}
