import SwiftUI
import UniformTypeIdentifiers

/// 文件页（对标安卓 FilesPage：多选栏 / FilesHeader / 搜索 / 分类 / 面包屑 / 工具行 / 列表与网格）
struct FilesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @State private var showImporter = false

    private var entries: (dirs: [JSON], files: [JSON]) {
        let q = state.query.lowercased()
        let dirs: [JSON]
        if state.category == 0 {
            dirs = state.folders
                .filter { q.isEmpty || $0["name"].string.lowercased().contains(q) }
                .sorted { $0["name"].string.lowercased() < $1["name"].string.lowercased() }
        } else {
            dirs = []
        }
        let docsLabels: Set<String> = ["文档", "PDF", "代码"]
        let files = state.files
            .filter { q.isEmpty || $0["name"].string.lowercased().contains(q) }
            .filter { item in
                switch state.category {
                case 1: return FileKind.kind(name: item["name"].string).label == "图片"
                case 2: return FileKind.kind(name: item["name"].string).label == "视频"
                case 3: return FileKind.kind(name: item["name"].string).label == "音频"
                case 4: return docsLabels.contains(FileKind.kind(name: item["name"].string).label)
                default: return true
                }
            }
            .sorted { a, b in
                switch state.sort {
                case 1: return a["updated_at"].string > b["updated_at"].string
                case 2: return a["size"].int64 > b["size"].int64
                default: return a["name"].string.lowercased() < b["name"].string.lowercased()
                }
            }
        return (dirs, files)
    }

    private var isEmptyAll: Bool {
        entries.dirs.isEmpty && entries.files.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !state.selected.isEmpty {
                SelectionBar()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    FilesHeader()
                    if state.selected.isEmpty {
                        searchBar.padding(.horizontal, 20)
                        Spacer().frame(height: 12)
                        categoryChips.padding(.horizontal, 20)
                    }
                    if state.folderId != nil {
                        breadcrumb
                    }
                    toolsRow.padding(.horizontal, 20)
                    Spacer().frame(height: 6)
                    content
                    Spacer().frame(height: 104)
                }
            }
            .refreshable { await state.refresh() }
        }
        .background(t.background)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                state.queueUpload(urls: urls)
            }
        }
        .overlay(alignment: .bottom) {
            if state.selected.isEmpty {
                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("上传文件").font(.gBodyLarge.weight(.semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .foregroundStyle(t.onPrimary)
                .background(t.primary)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(t.onSurfaceVariant)
            TextField("搜索当前文件夹", text: $state.query)
                .font(.gBodyMedium)
                .foregroundStyle(t.onSurface)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(t.onSurfaceVariant)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(t.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(t.outlineVariant, lineWidth: 1)
                }
        )
    }

    // MARK: - 分类 chips

    private var categoryChips: some View {
        let labels = ["全部", "图片", "视频", "音频", "文档"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Button {
                        state.category = index
                    } label: {
                        Text(label)
                            .font(.gLabelMedium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(state.category == index ? t.primary : t.onSurfaceVariant)
                            .background(state.category == index ? t.primaryContainer : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(state.category == index ? Color.clear : t.outlineVariant, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("全部文件") { state.enter(nil) }
                    .font(.gBodyMedium)
                    .foregroundStyle(t.primary)
                ForEach(state.breadcrumb, id: \.idValue) { crumb in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(t.onSurfaceVariant)
                    Button(crumb["name"].string) { state.enter(crumb) }
                        .font(.gBodyMedium)
                        .foregroundStyle(t.primary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 32)
    }

    // MARK: - 工具行

    private var toolsRow: some View {
        HStack(spacing: 0) {
            let count = entries.dirs.count + entries.files.count
            Text("\(count) 个项目")
                .font(.gLabelMedium)
                .foregroundStyle(t.onSurfaceVariant)
            Spacer()
            Button {
                state.nameDialog = NameDialogConfig(title: "新建文件夹", initial: "", item: nil, isFolder: true)
            } label: {
                Image(systemName: "folder.badge.plus").frame(width: 34, height: 34)
            }
            Menu {
                ForEach(Array(["名称 A → Z", "最近修改优先", "文件大小优先"].enumerated()), id: \.offset) { index, label in
                    Button {
                        state.sort = index
                    } label: {
                        HStack {
                            Text(label)
                            if state.sort == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").frame(width: 34, height: 34)
            }
            Button {
                state.grid.toggle()
            } label: {
                Image(systemName: state.grid ? "list.bullet" : "square.grid.2x2").frame(width: 34, height: 34)
            }
        }
        .font(.system(size: 16))
        .foregroundStyle(t.onSurfaceVariant)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if isEmptyAll && state.loadingFiles {
            FileListPlaceholder()
        } else if isEmptyAll {
            if !state.query.isEmpty {
                EmptyStateView(icon: "folder", title: "没有找到匹配文件", detail: "试试其他关键词或分类。")
            } else {
                EmptyStateView(icon: "folder", title: "还没有文件", detail: "上传照片、文档和灵感，随时随地取用。", actionTitle: "上传第一份文件") {
                    showImporter = true
                }
            }
        } else if state.grid {
            gridView
        } else {
            listView
        }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            ForEach(entries.dirs, id: \.idValue) { dir in
                FileRowView(item: dir, isDirectory: true)
                divider
            }
            ForEach(entries.files, id: \.idValue) { file in
                FileRowView(item: file, isDirectory: false)
                divider
            }
        }
        .padding(.horizontal, 20)
    }

    private var divider: some View {
        Rectangle()
            .fill(t.outlineVariant.opacity(0.65))
            .frame(height: 1)
            .padding(.leading, 64)
    }

    private var gridView: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(entries.dirs, id: \.idValue) { dir in
                FileTileView(item: dir, isDirectory: true)
            }
            ForEach(entries.files, id: \.idValue) { file in
                FileTileView(item: file, isDirectory: false)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - 多选操作栏（对标安卓 SelectionBar）

struct SelectionBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    var body: some View {
        HStack(spacing: 4) {
            Button {
                state.selected.removeAll()
            } label: {
                Image(systemName: "xmark").frame(width: 36, height: 36)
            }
            Text("已选择 \(state.selected.count) 项")
                .font(.gBodyMedium)
                .foregroundStyle(t.onSurface)
            Spacer()
            Button {
                let (dirs, _) = state.selectionItems()
                state.moveChooser = MoveConfig(
                    title: "移动 \(state.selected.count) 项到",
                    items: state.folders.filter { state.selected.contains("d" + $0["id"].string) }
                        + state.files.filter { state.selected.contains("f" + $0["id"].string) },
                    isFolders: state.folders.filter { state.selected.contains("d" + $0["id"].string) }.map { _ in true }
                        + state.files.filter { state.selected.contains("f" + $0["id"].string) }.map { _ in false },
                    excludedFolderIds: Set(dirs.map { $0["id"].int })
                )
            } label: {
                Image(systemName: "arrow.uturn.forward.folder").frame(width: 36, height: 36)
            }
            Button {
                state.batchDownload()
            } label: {
                Image(systemName: "arrow.down.circle").frame(width: 36, height: 36)
            }
            Button {
                state.confirm = ConfirmConfig(
                    title: "移入回收站",
                    detail: "所选文件和文件夹可在回收站恢复。",
                    danger: true
                ) {
                    Task { await state.batchDelete() }
                }
            } label: {
                Image(systemName: "trash").frame(width: 36, height: 36)
            }
        }
        .font(.system(size: 16))
        .foregroundStyle(t.onSurface)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(t.primaryContainer)
    }
}

// MARK: - 头部（对标安卓 FilesHeader）

struct FilesHeader: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    var title: String {
        if state.folderId == nil { return "我的文件" }
        return state.breadcrumb.last?["name"].string.isEmpty == false ? state.breadcrumb.last!["name"].string : "文件夹"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.siteName)
                        .font(.gLabelMedium)
                        .foregroundStyle(t.primary)
                    Text(title)
                        .font(.gHeadlineLarge)
                        .foregroundStyle(t.onSurface)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                }
                Button {
                    state.page = .main
                    state.tab = 4
                    Task { await state.load() }
                } label: {
                    AvatarView(client: state.client, name: state.displayName, avatarURL: state.user?["avatar_url"].stringValue, size: 46)
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(t.onSurfaceVariant)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
    }
}

// MARK: - 列表行（对标安卓 FileRow）

struct FileRowView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let item: JSON
    let isDirectory: Bool

    private var key: String { (isDirectory ? "d" : "f") + String(item["id"].int) }
    private var isSelected: Bool { state.selected.contains(key) }

    private var subtitle: String {
        if isDirectory { return "文件夹" }
        var s = ByteFmt.bytes(item["size"].int64)
        let ts = item["updated_at"].string.isEmpty ? item["created_at"].string : item["updated_at"].string
        if !ts.isEmpty {
            s += "  ·  " + ByteFmt.shortDate(ts)
        }
        return s
    }

    var body: some View {
        HStack(spacing: 0) {
            FileVisual(client: state.client, item: item, isDirectory: isDirectory, size: 48)
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        ZStack {
                            Circle().fill(.white)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(t.primary)
                        }
                        .frame(width: 20, height: 20)
                    }
                }
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(item["name"].string)
                    .font(.gBodyLarge.weight(.medium))
                    .foregroundStyle(t.onSurface)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.gLabelSmall)
                    .foregroundStyle(t.onSurfaceVariant)
            }
            .padding(.leading, 14)
            Spacer()
            Button {
                state.fileActions = FileActionContext(item: item, isDirectory: isDirectory)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(t.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.vertical, 12)
        .background(isSelected ? t.primaryContainer : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .onLongPressGesture(minimumDuration: 0.35) { state.toggleSelect(item, isDirectory: isDirectory) }
    }

    private func tap() {
        if !state.selected.isEmpty {
            state.toggleSelect(item, isDirectory: isDirectory)
        } else if isDirectory {
            state.enter(item)
        } else {
            state.previewFile = item
        }
    }
}

// MARK: - 网格卡（对标安卓 FileTile）

struct FileTileView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let item: JSON
    let isDirectory: Bool

    private var key: String { (isDirectory ? "d" : "f") + String(item["id"].int) }
    private var isSelected: Bool { state.selected.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                FileVisual(client: state.client, item: item, isDirectory: isDirectory, size: 76)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(t.primary)
                                .background(Circle().fill(.white))
                        }
                    }
                Button {
                    state.fileActions = FileActionContext(item: item, isDirectory: isDirectory)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(t.onSurfaceVariant)
                        .frame(width: 32, height: 32)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            Spacer().frame(height: 12)
            Text(item["name"].string)
                .font(.gBodyMedium.weight(.medium))
                .foregroundStyle(t.onSurface)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(minHeight: 36, alignment: .top)
            Spacer().frame(height: 7)
            Text(isDirectory ? "文件夹" : ByteFmt.bytes(item["size"].int64))
                .font(.gLabelSmall)
                .foregroundStyle(t.onSurfaceVariant)
        }
        .padding(14)
        .background(isSelected ? t.primaryContainer : t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? t.primary : t.outlineVariant.opacity(0.55), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap() }
        .onLongPressGesture(minimumDuration: 0.35) { state.toggleSelect(item, isDirectory: isDirectory) }
    }

    private func tap() {
        if !state.selected.isEmpty {
            state.toggleSelect(item, isDirectory: isDirectory)
        } else if isDirectory {
            state.enter(item)
        } else {
            state.previewFile = item
        }
    }
}

// MARK: - 骨架屏（对标安卓 FileListPlaceholder）

struct FileListPlaceholder: View {
    @Environment(\.gTheme) private var t
    @State private var visible = false

    var body: some View {
        VStack(spacing: 22) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(t.surfaceContainer)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(t.surfaceContainer).frame(width: 220, height: 12)
                        Capsule().fill(t.surfaceContainer).frame(width: 90, height: 8)
                    }
                    Spacer()
                }
            }
        }
        .padding(20)
        .opacity(visible ? 1 : 0)
        .task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            visible = true
        }
    }
}
