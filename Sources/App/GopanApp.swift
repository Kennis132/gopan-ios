import SwiftUI

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

/// 主题注入：accent + 明暗模式（对标安卓 Design.kt 主题逻辑）
struct ThemedRoot: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme
    let content: () -> AnyView

    private var dark: Bool {
        if state.themeMode == "dark" { return true }
        if state.themeMode == "light" { return false }
        return systemScheme == .dark
    }

    var body: some View {
        let palette = Palette.make(accentIndex: state.accentIndex, dark: dark)
        content()
            .environment(\.gTheme, palette)
            .preferredColorScheme(state.themeMode == "system" ? nil : (dark ? .dark : .light))
            .tint(palette.primary)
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ThemedRoot {
            AnyView(core)
        }
    }

    private var core: some View {
        Group {
            if state.booting {
                ZStack {
                    Color(hex: 0xF7F8F5).ignoresSafeArea()
                    ProgressView()
                }
            } else if state.user == nil {
                WelcomeView()
            } else {
                MainView()
            }
        }
        // 启动引导：恢复 Keychain 会话 / 迁移中断的传输任务
        .task { await state.bootstrap() }
        // 全局确认弹窗（对标安卓 ConfirmSheet）
        .alert(
            state.confirm?.title ?? "",
            isPresented: Binding(
                get: { state.confirm != nil },
                set: { if !$0 { state.confirm = nil } }
            )
        ) {
            Button("取消", role: .cancel) { state.confirm = nil }
            Button(state.confirm?.confirmText ?? "确定", role: state.confirm?.danger == true ? .destructive : nil) {
                let c = state.confirm
                state.confirm = nil
                c?.onConfirm()
            }
        } message: {
            Text(state.confirm?.detail ?? "")
        }
        // 预览页
        .fullScreenCover(item: $state.previewFile) { file in
            ThemedRoot { AnyView(PreviewView(file: file)) }
                .environmentObject(state)
        }
    }
}

/// 主框架（对标安卓 Scaffold：错误横幅 + 页面 + 底部导航 + FAB + snackbar + 弹层）
struct MainView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    var body: some View {
        VStack(spacing: 0) {
            if let failure = state.failure, !failure.isEmpty {
                HStack(spacing: 4) {
                    Text(failure)
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onErrorContainer)
                    Spacer()
                    Button("重试") {
                        Task { await state.refresh() }
                    }
                    .font(.gBodyMedium)
                    .foregroundStyle(t.onErrorContainer)
                    Button {
                        state.failure = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(t.onErrorContainer)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(t.errorContainer)
            }
            ZStack(alignment: .bottom) {
                content
                if let notice = state.notice, !notice.isEmpty {
                    Text(notice)
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onSurface)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(t.surfaceContainerHighest)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                        .padding(.bottom, 76)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            BottomNav()
        }
        .background(t.background)
        // 文件操作弹层
        .sheet(item: $state.fileActions) { ctx in
            ThemedRoot { AnyView(FileActionsSheet(ctx: ctx)) }
                .environmentObject(state)
        }
        // 重命名 / 新建文件夹
        .sheet(item: $state.nameDialog) { config in
            ThemedRoot { AnyView(NameDialogSheet(config: config)) }
                .environmentObject(state)
        }
        // 创建分享
        .sheet(item: $state.shareComposer) { ctx in
            ThemedRoot { AnyView(ShareComposerSheet(ctx: ctx)) }
                .environmentObject(state)
        }
        // 移动选择器
        .sheet(item: $state.moveChooser) { config in
            ThemedRoot { AnyView(MoveChooserSheet(config: config)) }
                .environmentObject(state)
        }
        // 查看他人分享
        .sheet(isPresented: $state.showShareViewer) {
            ThemedRoot { AnyView(ShareViewerSheet()) }
                .environmentObject(state)
        }
        // 修改密码 / 登录设备 / 编辑资料 / 写留言
        .sheet(isPresented: $state.showPasswordSheet) {
            ThemedRoot { AnyView(PasswordSheet()) }.environmentObject(state)
        }
        .sheet(isPresented: $state.showSessionSheet) {
            ThemedRoot { AnyView(SessionSheet()) }.environmentObject(state)
        }
        .sheet(isPresented: $state.showEditProfile) {
            ThemedRoot { AnyView(EditProfileSheet()) }.environmentObject(state)
        }
        .sheet(isPresented: $state.showMessageComposer) {
            ThemedRoot { AnyView(MessageComposerSheet()) }.environmentObject(state)
        }
        // 他人公开主页
        .sheet(item: $state.userSheet) { ctx in
            ThemedRoot { AnyView(UserSheetView(username: ctx.username)) }
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.page {
        case .recycle:
            RecycleView()
        case .settings:
            SettingsView()
        case .shares:
            SharesView()
        case .main:
            switch state.tab {
            case 0: FilesView()
            case 1: TransfersView()
            case 2: SharesView()
            case 3: CommunityView()
            default: ProfileView()
            }
        }
    }
}

/// 底部导航（对标安卓 DriveNavigation：云盘/传输/分享/留言板/我的）
struct BottomNav: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    private let tabs: [(label: String, icon: String)] = [
        ("云盘", "folder"),
        ("传输", "arrow.up.arrow.down"),
        ("分享", "link"),
        ("留言板", "bubble.left.and.bubble.right"),
        ("我的", "person"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tabInfo in
                Button {
                    if state.tab != index || state.page != .main {
                        state.selected.removeAll()
                        state.failure = nil
                        state.tab = index
                        state.page = .main
                        Task { await state.load() }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tabInfo.icon)
                            .font(.system(size: 19))
                        Text(tabInfo.label)
                            .font(.gLabelSmall)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .foregroundStyle(state.tab == index && state.page == .main ? t.primary : t.onSurfaceVariant)
                    .background(state.tab == index && state.page == .main ? t.primaryContainer : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(t.surface)
    }
}
