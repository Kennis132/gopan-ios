import SwiftUI
import UIKit

// MARK: - 字节格式化（对标安卓 MainActivity.bytes，zh_CN）

enum ByteFmt {
    static func bytes(_ value: Int64) -> String {
        let v = Double(value)
        if v < 1024 { return "\(value) B" }
        if v < 1048576 { return String(format: "%.1f KB", v / 1024.0) }
        if v < 1073741824 { return String(format: "%.1f MB", v / 1048576.0) }
        return String(format: "%.2f GB", v / 1073741824.0)
    }

    /// ISO 文本时间 "YYYY-MM-DD HH:MM:SS" → 前 10 位日期
    static func shortDate(_ iso: String) -> String {
        String(iso.prefix(10))
    }

    /// epoch 毫秒 → "yyyy-MM-dd HH:mm"
    static func dateTime(_ epochMs: Int64?) -> String {
        guard let ms = epochMs, ms > 0 else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - 文件类型映射（对标安卓 Design.kt kind()）

struct FileKind {
    let label: String
    let icon: String
    let tint: Color

    static func kind(name: String, isDirectory: Bool = false) -> FileKind {
        if isDirectory { return FileKind(label: "文件夹", icon: "folder.fill", tint: Color(hex: 0xCD9A40)) }
        let lower = name.lowercased()
        let ext = lower.contains(".") ? String(lower[lower.index(after: lower.lastIndex(of: ".")!)...]) : ""
        switch ext {
        case "png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "avif":
            return FileKind(label: "图片", icon: "photo", tint: Color(hex: 0x5089AA))
        case "mp4", "mov", "webm", "mkv", "avi":
            return FileKind(label: "视频", icon: "film", tint: Color(hex: 0x9878B9))
        case "mp3", "flac", "wav", "m4a", "aac", "ogg":
            return FileKind(label: "音频", icon: "music.note", tint: Color(hex: 0x579A8F))
        case "pdf":
            return FileKind(label: "PDF", icon: "doc.richtext", tint: Color(hex: 0xD56763))
        case "zip", "rar", "7z", "tar", "gz":
            return FileKind(label: "压缩包", icon: "doc.zipper", tint: Color(hex: 0xB99757))
        case "apk":
            return FileKind(label: "安装包", icon: "shippingbox", tint: Color(hex: 0x74A566))
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            return FileKind(label: "文档", icon: "doc.text", tint: Color(hex: 0x6E88BE))
        case "kt", "java", "py", "rs", "go", "json", "yaml", "xml", "ts":
            return FileKind(label: "代码", icon: "curlybraces", tint: Color(hex: 0x559AA9))
        default:
            return FileKind(label: "文档", icon: "doc", tint: Color(hex: 0x869487))
        }
    }
}

// MARK: - Cookie 图片加载（预览缩略图 / 头像，请求需带会话 Cookie）

final class CookieImageCache: @unchecked Sendable {
    static let shared = CookieImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private let inflight = NSLock()
    private var loading: Set<String> = []

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    func begin(_ key: String) -> Bool {
        inflight.lock(); defer { inflight.unlock() }
        if loading.contains(key) { return false }
        loading.insert(key)
        return true
    }

    func end(_ key: String) {
        inflight.lock(); loading.remove(key); inflight.unlock()
    }
}

/// 带会话 Cookie 的异步图片（对标安卓 AsyncImage 带 mediaHeaders）
struct CookieAsyncImage: View {
    var client: DriveClient
    var path: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
        }
        .task {
            if let cached = CookieImageCache.shared.image(for: path) {
                image = cached
                return
            }
            guard CookieImageCache.shared.begin(path) else { return }
            defer { CookieImageCache.shared.end(path) }
            guard let (data, response) = try? await client.stream(pathname: path),
                  (200..<300).contains(response.statusCode),
                  let ui = UIImage(data: data) else { return }
            CookieImageCache.shared.store(ui, for: path)
            image = ui
        }
    }
}

// MARK: - 文件图标视图（对标安卓 FileVisual）

struct FileVisual: View {
    @Environment(\.gTheme) private var t
    var client: DriveClient
    var item: JSON
    var isDirectory: Bool
    var size: CGFloat = 48

    var body: some View {
        let kind = FileKind.kind(name: item["name"].string, isDirectory: isDirectory)
        let isImageKind = ["图片"].contains(kind.label)
        ZStack(alignment: .bottomTrailing) {
            Group {
                if isImageKind, !isDirectory, item["id"].int > 0 {
                    CookieAsyncImage(client: client, path: "/api/files/\(item["id"].int)/preview")
                        .background(kind.tint.faint)
                } else {
                    kind.tint.faint
                        .overlay {
                            Image(systemName: kind.icon)
                                .font(.system(size: size * 0.48))
                                .foregroundStyle(kind.tint)
                        }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 14 / 48, style: .continuous))
        }
    }
}

// MARK: - 头像（对标安卓 Avatar）

struct AvatarView: View {
    @Environment(\.gTheme) private var t
    var client: DriveClient
    var name: String
    var avatarURL: String?
    var size: CGFloat = 44

    var body: some View {
        let initial = name.isEmpty ? "火" : String(name.prefix(1))
        ZStack {
            Circle().fill(t.primaryContainer)
            Text(initial)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(t.primary)
            if let avatarURL, !avatarURL.isEmpty {
                CookieAsyncImage(client: client, path: avatarURL)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - 共享容器与行（对标安卓 Panel / SectionTitle / SettingRow / Empty / PageHeader）

struct Panel<Content: View>: View {
    @Environment(\.gTheme) private var t
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(t.outlineVariant.opacity(0.45), lineWidth: 1)
            }
    }
}

struct SectionTitleView: View {
    @Environment(\.gTheme) private var t
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title).font(.gTitleMedium).foregroundStyle(t.onSurface)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.gLabelMedium)
                    .foregroundStyle(t.primary)
            }
        }
    }
}

struct SettingRow: View {
    @Environment(\.gTheme) private var t
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconColor: Color? = nil
    var chevron = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor ?? t.primary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.gBodyLarge).foregroundStyle(t.onSurface)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.gBodyMedium).foregroundStyle(t.onSurfaceVariant)
                    }
                }
                Spacer()
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.onSurfaceVariant)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyStateView: View {
    @Environment(\.gTheme) private var t
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(t.primaryContainer)
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(t.primary)
            }
            .frame(width: 88, height: 88)
            .padding(.top, 48)
            Spacer().frame(height: 22)
            Text(title).font(.gTitleLarge).foregroundStyle(t.onSurface)
            Spacer().frame(height: 8)
            Text(detail)
                .font(.gBodyMedium)
                .foregroundStyle(t.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let actionTitle, let action {
                Spacer().frame(height: 18)
                Button(action: action) {
                    Text(actionTitle).font(.gBodyMedium).padding(.horizontal, 16).padding(.vertical, 9)
                }
                .foregroundStyle(t.primary)
                .background(t.primaryContainer)
                .clipShape(Capsule())
            }
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 子页头部（对标安卓 PageHeader）：返回键 + 标题/副标题 + 右侧动作槽
struct PageHeader<Actions: View>: View {
    @Environment(\.gTheme) private var t
    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(t.onSurface)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.gHeadlineMedium).foregroundStyle(t.onSurface)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.gBodyMedium).foregroundStyle(t.onSurfaceVariant)
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

// MARK: - 表单输入框（对标安卓 OutlinedTextField 圆角 14）

struct GField: View {
    @Environment(\.gTheme) private var t
    let label: String
    var placeholder: String = ""
    var text: Binding<String>
    var secure = false
    var reveal = false
    var onToggleReveal: (() -> Void)? = nil
    var keyboard: UIKeyboardType = .default
    var supporting: String? = nil
    var icon: String? = nil
    var limit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if secure, !reveal {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.gBodyLarge)
            .foregroundStyle(t.onSurface)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: text.wrappedValue) { _, newValue in
                if let limit, newValue.count > limit {
                    text.wrappedValue = String(newValue.prefix(limit))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(t.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(t.outlineVariant, lineWidth: 1)
                    }
            )
            .overlay(alignment: .trailing) {
                if let onToggleReveal {
                    Button(action: onToggleReveal) {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(.system(size: 15))
                            .foregroundStyle(t.onSurfaceVariant)
                            .padding(.trailing, 12)
                    }
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(t.onSurfaceVariant)
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .leading) {
                if icon != nil && onToggleReveal == nil {
                    // leading icon 场景少，占位不处理
                    EmptyView()
                }
            }
            if let supporting {
                Text(supporting).font(.gLabelSmall).foregroundStyle(t.onSurfaceVariant)
            }
        }
    }
}

// MARK: - 底部弹层容器（对标安卓 ModalBottomSheet 风格）

struct BottomSheet<Content: View>: View {
    @Environment(\.gTheme) private var t
    @Binding var isPresented: Bool
    let content: Content

    init(isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        _isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .presentationDragIndicator(.visible)
            .presentationDetents([.large])
    }
}

// MARK: - 通用确认弹窗参数（对标安卓 ConfirmSheet）

struct ConfirmConfig: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var danger = false
    var confirmText = "确定"
    var onConfirm: () -> Void = {}
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
