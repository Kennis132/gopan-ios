# gopan-ios（篝火云盘 iOS 端）

gopan 云盘的 iOS 客户端。SwiftUI + URLSession 原生实现，与桌面端（Electron）、
安卓端（Kotlin/Compose）遵守同一套 `/api/*` 协议契约。

## 技术决策

- **无第三方依赖**：网络/JSON/加密全部用系统能力（URLSession、CryptoKit、Keychain）。
- **工程用 XcodeGen 定义**（`project.yml`），`.xcodeproj` 不进 git，CI 上生成——
  因为开发在 Windows 上进行，只在 GitHub Actions 的 macOS runner 上构建。
- **分发走免费自签**：CI 产出未签名 IPA，Sideloadly/爱思助手用免费 Apple ID 签名安装，
  不依赖付费开发者账号。
- **协议层逐行移植自桌面端** `src/main/`：
  - `Sources/Api/CookieJar.swift` ← `cookies.js`（Cookie 会话，保持插入序）
  - `Sources/Api/DriveClient.swift` ← `client.js`（全部端点 + CSRF 双提交）
  - `Sources/Config/ServerConfig.swift` ← `config.js`（站点根地址校验）
  - `Sources/Files/FileNameSanitizer.swift` ← `filenames.js`（本地名消毒/去重）
  - `Sources/Transfer/Uploader.swift` ← `uploads.js`（分片断点续传，16MiB/片、并发2、重试4次退避）
  - `Sources/Transfer/Downloader.swift` ← `downloads.js`（Range 续传、.part、sha256 校验）
  - `Sources/Storage/KeychainVault.swift` ← `vault.js`（凭据存储 → Keychain）
- 单元测试与桌面端 `test/unit.test.js` 同源，作为移植验收基准。

## 构建（GitHub Actions，无需 Mac）

push 到 main 或手动触发 workflow，跑完后在 Actions 页面下载产物
**`gopan-unsigned-ipa`**（未签名 IPA）。单元测试在 CI 上执行，编译失败会有日志 artifact。

## 安装到个人 iPhone（免费 Apple ID 自签，无需付费开发者账号）

1. 从 Actions 下载 `gopan-unsigned-ipa` 解压得到 `gopan-unsigned.ipa`；
2. Windows 上安装 [Sideloadly](https://sideloadly.io)（或用爱思助手的"自签安装"）；
3. iPhone 用数据线连电脑，Sideloadly 里拖入 IPA，填你的 Apple ID，Start——
   它会用免费证书签名并直接安装到手机（首次需在手机上信任开发者描述文件：
   设置 → 通用 → VPN与设备管理 → 信任你的 Apple ID）；
4. 限制与对策：
   - **签名 7 天有效**：到期前重跑一次 Sideloadly 覆盖安装即可，**数据保留**；
   - 免费证书同设备最多 3 个 App（不影响）；
   - 如果手机系统版本在 TrollStore 支持范围内（iOS 14.0–16.6.1 / 17.0 部分版本），
     可以用 TrollStore 永久安装，免 7 天重签；
   - 若以后想上 TestFlight / 长期分发，再考虑付费开发者账号，workflow 可随时加回签名步骤。

## 当前进度（对照安卓端 13 项功能清单）

已完成：

- [x] 协议层：登录/注册/登出、文件 CRUD/移动/回收站、分享、资料、分片上传协议、Cookie+CSRF
- [x] 传输层：分片上传（断点续传持久化到 Application Support）、Range 下载（.part、sha256）
- [x] 服务器地址校验（含公网明文 HTTP 确认开关）、文件名消毒
- [x] 会话持久化（Keychain）、401 全局登出
- [x] 最小 UI：登录/注册、文件浏览（面包屑/新建文件夹/重命名/删除/上传/下载/传输进度）

待办（移植路线）：

- [ ] 分享模块（创建/管理/公开查看/解锁）
- [ ] 回收站、留言板、我的（资料/头像/改密/会话管理）页面
- [ ] 预览（AVPlayer 带 Cookie 播放 / PDFKit / 图片缩放）
- [ ] 后台传输（URLSession background configuration）+ Live Activity
- [ ] Share Extension（系统分享接入上传）
- [ ] 设置页（主题/强调色/仅 Wi-Fi——`allowsConstrained`/`isExpensive` 判断）

## 目录结构

```
gopan-ios/
├── project.yml              # XcodeGen 工程定义
├── Config/Info.plist        # ATS 例外、文件分享等（xcodegen 生成/更新）
├── Sources/
│   ├── App/                 # SwiftUI 外壳
│   ├── Api/                 # DriveClient / CookieJar / JSON
│   ├── Config/              # 服务器地址校验
│   ├── Files/               # 文件名消毒
│   ├── Storage/             # Keychain 凭据
│   └── Transfer/            # 上传/下载管理器
├── Tests/                   # XCTest（与桌面端单测同源）
└── .github/workflows/ios.yml
```
