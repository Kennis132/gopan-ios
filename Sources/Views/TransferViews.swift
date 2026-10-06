import SwiftUI

/// 传输中心（对标安卓 TransfersPage：页头 / 分区 chips / 任务卡片）
struct TransfersView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    private var active: [TransferTask] { state.transferTasks.filter { $0.isActive } }
    private var finished: [TransferTask] { state.transferTasks.filter { !$0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "传输中心", subtitle: "上传和下载，都有迹可循") {
                HStack(spacing: 0) {
                    Button {
                        state.pauseAllTasks()
                        state.refreshTasks()
                    } label: {
                        Image(systemName: "pause.circle").frame(width: 36, height: 36)
                    }
                    Button {
                        state.clearFinishedTasks()
                        state.refreshTasks()
                    } label: {
                        Image(systemName: "delete.left").frame(width: 36, height: 36)
                    }
                }
                .font(.system(size: 17))
                .foregroundStyle(t.onSurfaceVariant)
            }
            HStack(spacing: 10) {
                segmentChip("进行中  \(active.count)", selected: state.transferSegment == 0) { state.transferSegment = 0 }
                segmentChip("已完成  \(finished.count)", selected: state.transferSegment == 1) { state.transferSegment = 1 }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if state.transferSegment == 0 {
                if active.isEmpty {
                    EmptyStateView(icon: "arrow.up.arrow.down", title: "暂时没有传输任务", detail: "从云盘上传或下载，任务会在这里持续更新。")
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(active) { task in
                                TransferCard(task: task)
                            }
                        }
                        .padding(20)
                    }
                }
            } else {
                if finished.isEmpty {
                    EmptyStateView(icon: "arrow.up.arrow.down", title: "还没有完成记录", detail: "从云盘上传或下载，任务会在这里持续更新。")
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(finished) { task in
                                TransferCard(task: task)
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .background(t.background)
        .task {
            // 处于传输页时轮询刷新（对标安卓 1s 轮询；iOS 由事件驱动，这里做镜像同步）
            while !Task.isCancelled {
                state.refreshTasks()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func segmentChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
}

/// 任务卡片（对标安卓 TransferCard）
struct TransferCard: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    let task: TransferTask
    @State private var quickLookURL: URL?

    private var fraction: Double {
        guard task.size > 0 else { return 0 }
        return min(1, max(0, Double(task.done) / Double(task.size)))
    }

    private var statusText: String {
        switch task.state {
        case .running:
            return task.kind == "upload" ? "正在上传" : "正在下载"
        case .queued:
            return "等待网络 / 系统调度"
        case .paused:
            return "已暂停"
        case .failed:
            return "传输失败"
        case .done:
            return "已完成"
        case .cancelled:
            return "已取消"
        }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(t.primaryContainer)
                        Image(systemName: task.kind == "upload" ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                            .font(.system(size: 19))
                            .foregroundStyle(t.primary)
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.name)
                            .font(.gTitleSmall)
                            .foregroundStyle(t.onSurface)
                            .lineLimit(2)
                        Text(task.state == .failed ? task.error : statusText)
                            .font(.gLabelSmall)
                            .foregroundStyle(task.state == .failed ? t.error : t.onSurfaceVariant)
                    }
                    Spacer()
                    if task.state == .done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(t.success)
                    }
                }
                Spacer().frame(height: 18)
                if task.state != .done && task.state != .cancelled {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(t.primaryContainer)
                            Capsule().fill(t.primary).frame(width: max(0, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 5)
                    .animation(.easeInOut(duration: 0.45), value: fraction)
                    Spacer().frame(height: 10)
                    HStack {
                        Text("\(ByteFmt.bytes(task.done)) / \(ByteFmt.bytes(task.size))")
                            .font(.gLabelSmall)
                            .foregroundStyle(t.onSurfaceVariant)
                        Spacer()
                        Text("\(Int(fraction * 100))%")
                            .font(.gLabelSmall)
                            .foregroundStyle(t.primary)
                    }
                }
                if !task.error.isEmpty && task.state != .failed {
                    Spacer().frame(height: 10)
                    Text(task.error).font(.gBodySmall).foregroundStyle(t.error)
                }
                if task.state == .running && task.speed > 0 {
                    Spacer().frame(height: 8)
                    Text("\(ByteFmt.bytes(task.speed))/s · 剩余 \(TransferRate.time(task.eta))")
                        .font(.gLabelSmall)
                        .foregroundStyle(t.onSurfaceVariant)
                }
                Spacer().frame(height: 12)
                buttons
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch task.state {
            case .running, .queued:
                Button {
                    state.pauseTask(task)
                } label: {
                    Label("暂停", systemImage: "pause")
                        .font(.gBodyMedium)
                }
                .foregroundStyle(t.primary)
            case .paused, .failed:
                Button {
                    state.resumeTask(task)
                } label: {
                    Label("继续", systemImage: "play")
                        .font(.gBodyMedium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .foregroundStyle(t.primary)
                .background(t.primaryContainer)
                .clipShape(Capsule())
            default:
                EmptyView()
            }
            if task.state != .done && task.state != .cancelled {
                Button {
                    state.confirm = ConfirmConfig(
                        title: "取消传输？",
                        detail: "断点和服务器预留空间会被释放。",
                        danger: true
                    ) {
                        state.cancelTask(task)
                    }
                } label: {
                    Text("取消").font(.gBodyMedium)
                }
                .foregroundStyle(t.onSurfaceVariant)
            }
            if task.state == .done, !task.localPath.isEmpty {
                if task.kind == "download" {
                    ShareLink(item: URL(fileURLWithPath: task.localPath)) {
                        Text("另存为").font(.gBodyMedium)
                    }
                    .foregroundStyle(t.primary)
                }
                Button {
                    quickLookURL = URL(fileURLWithPath: task.localPath)
                } label: {
                    Text("打开文件").font(.gBodyMedium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .foregroundStyle(t.primary)
                .background(t.primaryContainer)
                .clipShape(Capsule())
            }
        }
        .sheet(item: $quickLookURL) { url in
            QuickLookView(url: url)
                .ignoresSafeArea()
        }
    }
}

// MARK: - QuickLook 预览（打开已下载文件）

import QuickLook

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
