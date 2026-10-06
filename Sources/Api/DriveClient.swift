import Foundation

public typealias FetchImpl = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

private func networkCauseDescription(_ error: Error) -> String {
    guard let urlError = error as? URLError else { return error.localizedDescription }
    switch urlError.code {
    case .timedOut: return "ETIMEDOUT"
    case .cannotConnectToHost: return "ECONNREFUSED"
    case .cannotFindHost: return "ENOTFOUND"
    case .networkConnectionLost: return "ECONNRESET"
    case .notConnectedToInternet: return "ENETDOWN"
    default: return urlError.localizedDescription
    }
}

/// gopan API 客户端，逐行移植自桌面端 src/main/client.js：
/// Cookie 会话 + CSRF 双提交（POST/PUT/PATCH/DELETE 带 x-csrf-token 头）。
/// fetch 实现可注入，使协议层可以在没有网络的环境下做单元测试。
public final class DriveClient: @unchecked Sendable {
    private let baseURLProvider: @Sendable () -> String
    private let fetchImpl: FetchImpl
    private let lock = NSLock()
    private var jar = CookieJar()
    private var csrfToken: String?

    public init(baseURLProvider: @escaping @Sendable () -> String, fetch: FetchImpl? = nil) {
        self.baseURLProvider = baseURLProvider
        self.fetchImpl = fetch ?? DriveClient.defaultFetch
    }

    public static let defaultFetch: FetchImpl = { request in
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiError("无法连接服务器（无有效响应）", status: 0, code: "network")
            }
            return (data, http)
        } catch let e as ApiError {
            throw e
        } catch {
            throw ApiError("无法连接服务器（\(networkCauseDescription(error))）", status: 0, code: "network")
        }
    }

    public var baseURL: String { baseURLProvider() }

    public var authed: Bool {
        lock.lock(); defer { lock.unlock() }
        return jar.get("gopan_sess") != nil
    }

    public var csrf: String? {
        lock.lock(); defer { lock.unlock() }
        return csrfToken
    }

    public func resetSession() {
        lock.lock(); defer { lock.unlock() }
        jar = CookieJar()
        csrfToken = nil
    }

    // MARK: - 底层收发

    private func absoluteURL(_ pathname: String) throws -> URL {
        let base = baseURLProvider()
        guard !base.isEmpty, let url = URL(string: base + pathname) else {
            throw ApiError("还没有配置服务器地址", status: 0, code: "no_server")
        }
        return url
    }

    private static func isMutation(_ method: String) -> Bool {
        ["POST", "PUT", "PATCH", "DELETE"].contains(method)
    }

    @discardableResult
    private func send(_ method: String, _ pathname: String, body: JSON? = nil, rawBody: Data? = nil, headers: [String: String] = [:], includeCSRF: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let url = try absoluteURL(pathname)
        var request = URLRequest(url: url)
        request.httpMethod = method

        lock.lock()
        let cookie = jar.header()
        let csrf = csrfToken
        lock.unlock()

        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if includeCSRF, Self.isMutation(method), let csrf {
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let rawBody {
            request.httpBody = rawBody
        } else if let body {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = try body.encodedData()
        }

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await fetchImpl(request)
        } catch let e as ApiError {
            throw e
        } catch {
            throw ApiError("无法连接服务器（\(networkCauseDescription(error))）", status: 0, code: "network")
        }
        captureCookies(from: response)
        return (data, response)
    }

    private func requestJSON(_ method: String, _ pathname: String, body: JSON? = nil, rawBody: Data? = nil, headers: [String: String] = [:]) async throws -> JSON {
        let (data, response) = try await send(method, pathname, body: body, rawBody: rawBody, headers: headers)
        let text = String(data: data, encoding: .utf8) ?? ""
        var parsed: JSON?
        if !text.isEmpty {
            guard let p = try? JSON(data: data) else {
                throw ApiError("服务器返回了非 JSON 响应 (\(response.statusCode))", status: response.statusCode, code: "bad_json")
            }
            parsed = p
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ApiError(
                parsed?["error"].stringValue ?? "请求失败 (\(response.statusCode))",
                status: response.statusCode,
                code: parsed?["code"].stringValue
            )
        }
        return parsed ?? .null
    }

    /// URLSession 会把多个 Set-Cookie 合并进一个头，按桌面端同款启发式拆开
    static func splitMergedSetCookie(_ raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: ",(?=[^;]+?=)") else { return [raw] }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        var parts: [String] = []
        var start = 0
        for m in matches {
            parts.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + 1
        }
        parts.append(ns.substring(from: start))
        return parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t")) }.filter { !$0.isEmpty }
    }

    private func captureCookies(from response: HTTPURLResponse) {
        var lines: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let k = key as? String, k.lowercased() == "set-cookie", let v = value as? String else { continue }
            lines.append(contentsOf: Self.splitMergedSetCookie(v))
        }
        lock.lock(); defer { lock.unlock() }
        jar.add(setCookieLines: lines)
        if let c = jar.get("gopan_csrf") {
            csrfToken = c
        }
    }

    /// 下载/流式请求走的 URLSession 响应也回灌 Cookie（对应 client.js 的 stream()）
    public func noteResponse(_ response: HTTPURLResponse) {
        captureCookies(from: response)
    }

    // MARK: - auth

    @discardableResult
    public func login(_ username: String, _ password: String) async throws -> JSON {
        try await requestJSON("POST", "/api/auth/login", body: ["username": .string(username), "password": .string(password)])
    }

    @discardableResult
    public func register(_ username: String, _ password: String) async throws -> JSON {
        try await requestJSON("POST", "/api/auth/register", body: ["username": .string(username), "password": .string(password)])
    }

    @discardableResult
    public func logout() async throws -> JSON {
        try await requestJSON("POST", "/api/auth/logout", body: .object([:]))
    }

    @discardableResult
    public func me() async throws -> JSON {
        try await requestJSON("GET", "/api/auth/me")
    }

    @discardableResult
    public func site() async throws -> JSON {
        try await requestJSON("GET", "/api/site")
    }

    // MARK: - files

    @discardableResult
    public func listFiles(folderId: Int? = nil) async throws -> JSON {
        let q = folderId.map { "?folderId=\($0)" } ?? ""
        return try await requestJSON("GET", "/api/files\(q)")
    }

    @discardableResult
    public func fileMeta(id: Int) async throws -> JSON {
        try await requestJSON("GET", "/api/files/meta/\(id)")
    }

    @discardableResult
    public func mkdir(_ name: String, parentId: Int? = nil) async throws -> JSON {
        try await requestJSON("POST", "/api/files/folder", body: ["name": .string(name), "parentId": parentId.map(JSON.int) ?? .null])
    }

    @discardableResult
    public func renameFile(id: Int, name: String) async throws -> JSON {
        try await requestJSON("PATCH", "/api/files/\(id)", body: ["name": .string(name)])
    }

    @discardableResult
    public func renameFolder(id: Int, name: String) async throws -> JSON {
        try await requestJSON("PATCH", "/api/files/folder/\(id)", body: ["name": .string(name)])
    }

    @discardableResult
    public func moveFile(id: Int, folderId: Int) async throws -> JSON {
        try await requestJSON("POST", "/api/files/\(id)/move", body: ["folderId": .int(folderId)])
    }

    @discardableResult
    public func moveFolder(id: Int, folderId: Int) async throws -> JSON {
        try await requestJSON("POST", "/api/files/folder/\(id)/move", body: ["folderId": .int(folderId)])
    }

    @discardableResult
    public func deleteFile(id: Int) async throws -> JSON {
        try await requestJSON("DELETE", "/api/files/\(id)")
    }

    @discardableResult
    public func deleteFolder(id: Int) async throws -> JSON {
        try await requestJSON("DELETE", "/api/files/folder/\(id)")
    }

    // MARK: - recycle

    @discardableResult
    public func recycleList() async throws -> JSON {
        try await requestJSON("GET", "/api/files/recycle/list")
    }

    @discardableResult
    public func restoreFile(id: Int) async throws -> JSON {
        try await requestJSON("POST", "/api/files/recycle/\(id)/restore", body: .object([:]))
    }

    @discardableResult
    public func purgeFile(id: Int) async throws -> JSON {
        try await requestJSON("DELETE", "/api/files/recycle/\(id)")
    }

    @discardableResult
    public func restoreFolder(id: Int) async throws -> JSON {
        try await requestJSON("POST", "/api/files/recycle/folder/\(id)/restore", body: .object([:]))
    }

    @discardableResult
    public func purgeFolder(id: Int) async throws -> JSON {
        try await requestJSON("DELETE", "/api/files/recycle/folder/\(id)")
    }

    // MARK: - shares

    @discardableResult
    public func createShare(_ input: JSON) async throws -> JSON {
        try await requestJSON("POST", "/api/shares", body: input)
    }

    @discardableResult
    public func listShares() async throws -> JSON {
        try await requestJSON("GET", "/api/shares")
    }

    @discardableResult
    public func deleteShare(id: Int) async throws -> JSON {
        try await requestJSON("DELETE", "/api/shares/\(id)")
    }

    // MARK: - profile

    @discardableResult
    public func profile() async throws -> JSON {
        try await requestJSON("GET", "/api/me")
    }

    @discardableResult
    public func updateProfile(_ displayName: String, _ bio: String) async throws -> JSON {
        try await requestJSON("PATCH", "/api/me", body: ["displayName": .string(displayName), "bio": .string(bio)])
    }

    @discardableResult
    public func uploadAvatar(_ data: Data, contentType: String) async throws -> JSON {
        try await requestJSON("POST", "/api/me/avatar", rawBody: data, headers: ["Content-Type": contentType])
    }

    @discardableResult
    public func removeAvatar() async throws -> JSON {
        try await requestJSON("DELETE", "/api/me/avatar")
    }

    @discardableResult
    public func changePassword(_ oldPassword: String, _ newPassword: String) async throws -> JSON {
        try await requestJSON("POST", "/api/me/password", body: ["oldPassword": .string(oldPassword), "newPassword": .string(newPassword)])
    }

    // MARK: - resumable upload (/api/uploads)

    @discardableResult
    public func uploadInit(name: String, size: Int64, folderId: Int?) async throws -> JSON {
        try await requestJSON("POST", "/api/uploads/init", body: ["name": .string(name), "size": .int(Int(size)), "folderId": folderId.map(JSON.int) ?? .null])
    }

    @discardableResult
    public func uploadStatus(uploadId: String) async throws -> JSON {
        try await requestJSON("GET", "/api/uploads/\(uploadId)")
    }

    @discardableResult
    public func uploadChunk(uploadId: String, index: Int, data: Data) async throws -> JSON {
        try await requestJSON("PUT", "/api/uploads/\(uploadId)/chunk/\(index)", rawBody: data, headers: ["Content-Type": "application/octet-stream"])
    }

    @discardableResult
    public func uploadComplete(uploadId: String, mime: String) async throws -> JSON {
        try await requestJSON("POST", "/api/uploads/\(uploadId)/complete", body: ["mime": .string(mime)])
    }

    @discardableResult
    public func uploadAbandon(uploadId: String) async throws -> JSON {
        try await requestJSON("DELETE", "/api/uploads/\(uploadId)")
    }

    // MARK: - sessions（登录设备）

    @discardableResult
    public func sessions() async throws -> JSON {
        try await requestJSON("GET", "/api/me/sessions")
    }

    @discardableResult
    public func revokeOtherSessions() async throws -> JSON {
        try await requestJSON("DELETE", "/api/me/sessions")
    }

    // MARK: - guestbook（留言板）

    @discardableResult
    public func guestbook(limit: Int = 50) async throws -> JSON {
        try await requestJSON("GET", "/api/guestbook?limit=\(limit)")
    }

    @discardableResult
    public func postGuestbook(_ message: String) async throws -> JSON {
        try await requestJSON("POST", "/api/guestbook", body: ["message": .string(message)])
    }

    @discardableResult
    public func deleteGuestbook(id: Int) async throws -> JSON {
        try await requestJSON("DELETE", "/api/guestbook/\(id)")
    }

    // MARK: - shares 扩展

    @discardableResult
    public func patchShare(id: Int, visibility: String) async throws -> JSON {
        try await requestJSON("PATCH", "/api/shares/\(id)", body: ["visibility": .string(visibility)])
    }

    // MARK: - 公开分享（查看他人分享）

    @discardableResult
    public func publicShare(token: String) async throws -> JSON {
        try await requestJSON("GET", "/api/public/shares/\(token)")
    }

    @discardableResult
    public func unlockShare(token: String, password: String?) async throws -> JSON {
        try await requestJSON("POST", "/api/public/shares/\(token)/unlock", body: ["password": password.map(JSON.string) ?? .null])
    }

    /// 分享文件下载请求（ticket 一次性 5 分钟有效）
    public func makeShareFileRequest(token: String, ticket: String) throws -> URLRequest {
        try makeStreamRequest(pathname: "/api/public/shares/\(token)/file?ticket=\(ticket)")
    }

    /// 通用 API 请求构造（HEAD 预览探测等），带会话 Cookie，不加 CSRF
    public func makeRequest(method: String, pathname: String) throws -> URLRequest {
        let url = try absoluteURL(pathname)
        var request = URLRequest(url: url)
        request.httpMethod = method
        lock.lock()
        let cookie = jar.header()
        lock.unlock()
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    // MARK: - 公开用户主页

    @discardableResult
    public func usersPublicProfile(_ username: String) async throws -> JSON {
        try await requestJSON("GET", "/api/users/\(username)")
    }

    // MARK: - streaming（下载管理器 / 媒体播放用）

    public func makeStreamRequest(pathname: String, range: String? = nil) throws -> URLRequest {
        let url = try absoluteURL(pathname)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        lock.lock()
        let cookie = jar.header()
        lock.unlock()
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    @discardableResult
    public func stream(pathname: String, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let request = try makeStreamRequest(pathname: pathname, range: range)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiError("无法连接服务器（无有效响应）", status: 0, code: "network")
            }
            noteResponse(http)
            return (data, http)
        } catch let e as ApiError {
            throw e
        } catch {
            throw ApiError("无法连接服务器（\(networkCauseDescription(error))）", status: 0, code: "network")
        }
    }

    // MARK: - 会话序列化（Keychain 持久化用）

    public func serializeJar() -> [Cookie] {
        lock.lock(); defer { lock.unlock() }
        return jar.toJSON()
    }

    @discardableResult
    public func restoreJar(_ cookies: [Cookie]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        jar = CookieJar(cookies: cookies)
        csrfToken = jar.get("gopan_csrf")
        return jar.get("gopan_sess") != nil
    }
}
