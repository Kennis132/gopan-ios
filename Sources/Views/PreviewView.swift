import SwiftUI
import AVKit
import PDFKit

/// 预览页（对标安卓 PreviewActivity：HEAD 探测 / 图片缩放 / 音视频 / PDF / 文本 / 不支持引导）
struct PreviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t
    @Environment(\.dismiss) private var dismiss
    let file: JSON

    @State private var contentType: String?
    @State private var failure: String?
    @State private var loading = true

    private var previewPath: String { "/api/files/\(file["id"].int)/preview" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().foregroundStyle(t.outlineVariant)
            ZStack {
                if loading {
                    ProgressView()
                } else if let failure, !failure.isEmpty {
                    failureView(failure)
                } else {
                    content
                }
                VStack {
                    Spacer()
                    if let f = state.failure, !f.isEmpty {
                        Text(f)
                            .font(.gBodyMedium)
                            .foregroundStyle(t.error)
                            .padding(16)
                            .background(t.primaryContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(.bottom, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(t.background)
        .task { await probe() }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(t.onSurface)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file["name"].string)
                    .font(.gTitleMedium)
                    .foregroundStyle(t.onSurface)
                    .lineLimit(1)
                Text(ByteFmt.bytes(file["size"].int64))
                    .font(.gLabelSmall)
                    .foregroundStyle(t.onSurfaceVariant)
            }
            Spacer()
            Button {
                state.queueDownload(file: file)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(t.onSurfaceVariant)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.badge.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(t.onSurfaceVariant)
            Text(message)
                .font(.gBodyMedium)
                .foregroundStyle(t.onSurfaceVariant)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("重试") {
                    Task { await probe() }
                }
                .font(.gBodyMedium)
                .foregroundStyle(t.primary)
                Button {
                    state.queueDownload(file: file)
                } label: {
                    Text("下载后打开")
                        .font(.gBodyMedium)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .foregroundStyle(t.primary)
                .background(t.primaryContainer)
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - 类型路由

    @ViewBuilder
    private var content: some View {
        let type = contentType ?? ""
        if type.hasPrefix("image/") {
            ZoomableImage(client: state.client, path: previewPath)
        } else if type.hasPrefix("video/") {
            MediaPreview(client: state.client, path: previewPath, isAudio: false)
        } else if type.hasPrefix("audio/") {
            MediaPreview(client: state.client, path: previewPath, isAudio: true)
        } else if type.contains("pdf") {
            DocumentPreview(client: state.client, path: previewPath, isPDF: true)
        } else if type.hasPrefix("text/") || type.contains("json") {
            DocumentPreview(client: state.client, path: previewPath, isPDF: false)
        } else {
            EmptyStateView(icon: "doc", title: "此格式暂不支持预览", detail: "可下载后使用对应应用打开。", actionTitle: "下载文件") {
                state.queueDownload(file: file)
            }
        }
    }

    private func probe() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let request = try state.client.makeRequest(method: "HEAD", pathname: previewPath)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                failure = "服务器不支持预览"
                return
            }
            contentType = http.value(forHTTPHeaderField: "Content-Type")
        } catch {
            failure = (error as? ApiError)?.message ?? "连接中断，请重试"
        }
    }
}

// MARK: - 图片缩放（对标安卓 ZoomImage：scale 1-6，回正中）

struct ZoomableImage: View {
    @Environment(\.gTheme) private var t
    var client: DriveClient
    var path: String

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        ZStack {
            t.background
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale * gestureScale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .updating($gestureScale) { value, state, _ in state = value }
                            .onEnded { value in
                                scale = min(6, max(1, scale * value))
                                if scale == 1 { offset = .zero }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1 {
                                    offset = value.translation
                                }
                            }
                            .onEnded { _ in
                                if scale == 1 { offset = .zero }
                            }
                    )
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            Text("双指缩放与拖动")
                .font(.gLabelSmall)
                .foregroundStyle(t.onSurfaceVariant)
                .padding(.bottom, 20)
        }
        .task {
            if let (data, response) = try? await client.stream(pathname: path),
               (200..<300).contains(response.statusCode) {
                image = UIImage(data: data)
            }
        }
    }
}

// MARK: - 音视频播放（对标安卓 MediaPreview：Cookie 头、进入即播、音频常显控制条）

import MediaPlayer

struct MediaPreview: View {
    @Environment(\.gTheme) private var t
    var client: DriveClient
    var path: String
    var isAudio: Bool
    @State private var player: AVPlayer?
    @State private var playError = false

    var body: some View {
        VStack {
            if isAudio {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 60))
                    .foregroundStyle(t.primary)
                Spacer().frame(height: 24)
                if playError {
                    Text("播放失败：设备或服务器不支持该媒体格式")
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onSurfaceVariant)
                        .frame(height: 160)
                        .padding(.horizontal, 16)
                } else if let player {
                    PlayerControllerView(player: player)
                        .frame(height: 160)
                        .padding(.horizontal, 16)
                } else {
                    ProgressView().frame(height: 160)
                }
                Spacer()
            } else {
                if playError {
                    Text("播放失败：设备或服务器不支持该媒体格式")
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onSurfaceVariant)
                } else if let player {
                    PlayerControllerView(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            // Cookie 鉴权：服务端流媒体需要会话 Cookie（对应安卓 OkHttpDataSource 带 mediaHeaders）
            guard let url = URL(string: client.baseURL + path) else { return }
            let headers: [String: String] = ["Cookie": cookieHeader]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let item = AVPlayerItem(asset: asset)
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
            // 监听播放失败（对标安卓播放器错误文案）
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { _ in
                playError = true
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var cookieHeader: String {
        client.serializeJar().map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

struct PlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

// MARK: - PDF / 文本（对标安卓 DocumentPreview）

struct DocumentPreview: View {
    @Environment(\.gTheme) private var t
    var client: DriveClient
    var path: String
    var isPDF: Bool

    @State private var pdfDocument: PDFDocument?
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure, !failure.isEmpty {
                Text(failure)
                    .font(.gBodyMedium)
                    .foregroundStyle(t.onSurfaceVariant)
            } else if isPDF {
                if let pdfDocument {
                    PDFKitView(document: pdfDocument)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                }
            } else if let text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(t.onSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let (data, response) = try await client.stream(pathname: path)
            guard (200..<300).contains(response.statusCode) else {
                failure = "无法预览"
                return
            }
            if isPDF {
                // 上限 64MB（对标安卓）
                if data.count > 64 * 1024 * 1024 {
                    failure = "内容过大，请下载后打开"
                    return
                }
                pdfDocument = PDFDocument(data: data)
                if pdfDocument == nil { failure = "无法读取文档" }
            } else {
                if data.count > 2 * 1024 * 1024 {
                    failure = "内容过大，请下载后打开"
                    return
                }
                text = String(data: data, encoding: .utf8) ?? "（无法按 UTF-8 解码）"
            }
        } catch {
            failure = (error as? ApiError)?.message ?? "无法预览"
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .white
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = document
    }
}
