import SwiftUI

/// 登录页（对标安卓 Welcome.kt：logo 渐变 / 大标题 / Panel 表单 / HTTP 确认）
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.gTheme) private var t

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 32)
                    logo
                    Spacer().frame(height: 30)
                    Text("你的文件，\n随身安放。")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(t.onSurface)
                    Spacer().frame(height: 14)
                    Text("\(state.siteName) · 连接属于你的私人空间")
                        .font(.gBodyMedium)
                        .foregroundStyle(t.onSurfaceVariant)
                    Spacer().frame(height: 34)
                    panel
                    Spacer().frame(height: 28)
                    HStack(spacing: 8) {
                        Image(systemName: "shield")
                            .font(.system(size: 11))
                            .foregroundStyle(t.onSurfaceVariant)
                        Text("文件保存在你的服务器，凭据由系统加密保管。")
                            .font(.gLabelSmall)
                            .foregroundStyle(t.onSurfaceVariant)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 26)
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(t.background)
        }
        .task {
            // 进入登录页时预取站点信息（对标安卓 LaunchedEffect）
            if !state.client.baseURL.isEmpty && !state.siteLoaded {
                await state.loadSite()
            }
        }
        .alert("使用 HTTP 连接？", isPresented: $state.confirmHTTP) {
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task { await state.submitLogin() }
            }
        } message: {
            Text("该连接不会加密账号和文件内容。可信局域网可使用，公网建议 HTTPS。")
        }
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(LinearGradient(
                    colors: [GO_PAN_ACCENTS[0], Color(hex: 0xF29B67)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Image(systemName: "flame.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
        }
        .frame(width: 74, height: 74)
    }

    private var panel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(state.loginRegister ? "创建你的账户" : "欢迎回来")
                        .font(.gTitleLarge)
                        .foregroundStyle(t.onSurface)
                    Spacer()
                    Button(state.loginRegister ? "去登录" : "注册") {
                        state.loginRegister.toggle()
                        state.loginError = ""
                    }
                    .font(.gLabelMedium)
                    .foregroundStyle(t.primary)
                }
                Spacer().frame(height: 18)
                GField(label: "服务器地址", placeholder: "https://drive.example.com", text: $state.loginServer, keyboard: .URL, icon: "network")
                Spacer().frame(height: 14)
                GField(label: "用户名", placeholder: "用户名", text: $state.loginUsername, icon: "person")
                Spacer().frame(height: 14)
                GField(label: "密码", placeholder: "密码", text: $state.loginPassword, secure: true, reveal: state.loginReveal, onToggleReveal: { state.loginReveal.toggle() })
                if !state.loginError.isEmpty {
                    Spacer().frame(height: 16)
                    Text(state.loginError)
                        .font(.gBodyMedium)
                        .foregroundStyle(t.error)
                }
                Spacer().frame(height: 22)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 10) {
                        if state.loginBusy {
                            ProgressView()
                                .tint(t.onPrimary)
                                .frame(width: 18, height: 18)
                        }
                        Text(state.loginBusy ? "正在连接…" : (state.loginRegister ? "注册并进入" : "登录云盘"))
                            .font(.gBodyLarge.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .foregroundStyle(t.onPrimary)
                .background(t.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(state.loginBusy || state.loginServer.trimmingCharacters(in: .whitespaces).isEmpty || state.loginUsername.trimmingCharacters(in: .whitespaces).isEmpty || state.loginPassword.isEmpty)
                .opacity(state.loginBusy || state.loginServer.isEmpty || state.loginUsername.isEmpty || state.loginPassword.isEmpty ? 0.55 : 1)
                Spacer().frame(height: 14)
                Text("支持 HTTPS 与可信局域网。注册规则由服务器决定。")
                    .font(.gLabelSmall)
                    .foregroundStyle(t.onSurfaceVariant)
            }
        }
    }

    private func submit() {
        let raw = state.loginServer.trimmingCharacters(in: .whitespaces)
        // 对标安卓：以 http:// 开头需确认
        if raw.lowercased().hasPrefix("http://") {
            state.confirmHTTP = true
            return
        }
        Task { await state.submitLogin() }
    }
}
