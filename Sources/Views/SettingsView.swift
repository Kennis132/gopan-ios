import SwiftUI
import UIKit
import UserNotifications

/// 设置页（对标安卓 SettingsPage：外观 / 传输与提醒 / 系统 / 服务器与关于 / 管理员）
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @Environment(\.colorScheme) private var systemScheme
    @State private var showAbout = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置", subtitle: "按你的习惯使用云盘") {
                Button {
                    state.page = .main
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(t.onSurface)
                }
            }
            ScrollView {
                VStack(spacing: 18) {
                    appearancePanel
                    transferPanel
                    systemGroup
                    serverGroup
                    if state.user?["role"].string == "admin" {
                        adminPanel
                    }
                }
                .padding(20)
            }
        }
        .background(t.background)
        .alert(state.siteName, isPresented: $showAbout) {
            Button("完成", role: .cancel) {}
        } message: {
            Text("原生 SwiftUI 客户端。\n\n文件、分享、回收站、留言板和账户与现有服务端同步。没有广告与统计 SDK。下载默认保存在应用私有空间，可另存到系统目录。卸载会清除本地文件。")
        }
    }

    // MARK: - 外观

    private var appearancePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitleView(title: "外观")
                Spacer().frame(height: 12)
                HStack(spacing: 8) {
                    themeChip("system", "跟随系统")
                    themeChip("light", "浅色")
                    themeChip("dark", "深色")
                }
                Spacer().frame(height: 18)
                Text("强调色").font(.gBodyMedium).foregroundStyle(t.onSurface)
                Spacer().frame(height: 14)
                HStack(spacing: 18) {
                    ForEach(Array(GO_PAN_ACCENTS.enumerated()), id: \.offset) { index, color in
                        Button {
                            state.accentIndex = index
                        } label: {
                            ZStack {
                                Circle().fill(color)
                                if state.accentIndex == index {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func themeChip(_ key: String, _ label: String) -> some View {
        let selected = state.themeMode == key
        return Button {
            state.themeMode = key
        } label: {
            Text(label)
                .font(.gLabelMedium)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? t.primary : t.onSurfaceVariant)
                .background(selected ? t.primaryContainer : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.clear : t.outlineVariant, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 传输与提醒

    private var transferPanel: some View {
        Panel {
            VStack(spacing: 0) {
                SectionTitleView(title: "传输与提醒")
                Spacer().frame(height: 8)
                ToggleRow(
                    title: "仅非计费网络传输",
                    detail: "通常为 Wi-Fi，对之后启动或恢复的任务生效。",
                    isOn: $state.wifiOnly
                )
                Divider().foregroundStyle(t.outlineVariant).padding(.vertical, 12)
                ToggleRow(
                    title: "留言与公告提醒",
                    detail: "打开后会请求系统通知权限，用于留言更新提醒。",
                    isOn: $state.messageNotify
                )
                .onChange(of: state.messageNotify) { _, on in
                    if on {
                        Task {
                            let center = UNUserNotificationCenter.current()
                            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                        }
                    }
                }
            }
        }
    }

    // MARK: - 系统设置组

    private var systemGroup: some View {
        VStack(spacing: 0) {
            SettingRow(icon: "bell.slash", title: "通知权限", subtitle: "传输进度、结果与留言提醒") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Divider().foregroundStyle(t.outlineVariant)
            SettingRow(icon: "rectangle.on.rectangle", title: "实时活动", subtitle: "在系统通知设置中管理传输实时活动") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 16)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - 服务器与关于

    private var serverGroup: some View {
        VStack(spacing: 0) {
            SettingRow(icon: "network", title: "服务器", subtitle: state.client.baseURL) {
                state.confirm = ConfirmConfig(
                    title: "切换服务器？",
                    detail: "当前任务会暂停，旧会话会清除。之后可填写新的服务器地址。"
                ) {
                    Task { await state.switchServer() }
                }
            }
            Divider().foregroundStyle(t.outlineVariant)
            SettingRow(icon: "info.circle", title: "关于\(state.siteName)", subtitle: "1.0.0 · 原生 iOS 客户端") {
                showAbout = true
            }
        }
        .padding(.horizontal, 16)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - 管理员

    private var adminPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitleView(title: "管理员")
                Spacer().frame(height: 10)
                Text("服务端的管理能力可通过原站点查看，移动端账户操作与服务端权限同步。")
                    .font(.gBodyMedium)
                    .foregroundStyle(t.onSurfaceVariant)
                Spacer().frame(height: 12)
                Button("打开站点管理") {
                    if let url = URL(string: state.client.baseURL) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.gLabelMedium)
                .foregroundStyle(t.primary)
            }
        }
    }
}

/// 开关行（对标安卓 Switch 行）
struct ToggleRow: View {
    @Environment(\.gTheme) private var t
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.gBodyLarge).foregroundStyle(t.onSurface)
                Text(detail).font(.gBodyMedium).foregroundStyle(t.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(t.primary)
        }
        .padding(.vertical, 8)
    }
}
