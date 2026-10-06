import XCTest
@testable import gopan

/// 与桌面端 test/unit.test.js 的 client 用例同源：用注入的 fetch 存根验证
/// Cookie 会话捕获、CSRF 双提交、错误保留 status/code。
final class DriveClientTests: XCTestCase {
    struct TestFailure: Error {}

    final class FetchStub: @unchecked Sendable {
        struct Stub {
            var status = 200
            var body = ""
            var setCookie: [String] = []
            var error: Error?
        }

        struct Call {
            var url: String
            var method: String
            var headers: [String: String]
            var body: Data?
        }

        private let lock = NSLock()
        var queue: [Stub]
        private(set) var calls: [Call] = []

        init(_ queue: [Stub]) {
            self.queue = queue
        }

        func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); defer { lock.unlock() }
            var headers: [String: String] = [:]
            for (k, v) in request.allHTTPHeaderFields ?? [:] {
                headers[k.lowercased()] = v
            }
            calls.append(Call(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "", headers: headers, body: request.httpBody))
            guard !queue.isEmpty else { throw TestFailure() }
            let stub = queue.removeFirst()
            if let error = stub.error { throw error }
            var hdrs: [String: String] = [:]
            if !stub.setCookie.isEmpty {
                hdrs["Set-Cookie"] = stub.setCookie.joined(separator: ", ")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: hdrs)!
            return (Data(stub.body.utf8), response)
        }
    }

    private let baseURL = "http://127.0.0.1:8787"

    func testLoginCapturesSessionAndCSRFMutationsEchoToken() async throws {
        let stub = FetchStub([
            .init(status: 200, body: #"{"ok":true,"user":{"username":"tester"},"csrf":"tok"}"#, setCookie: [
                "gopan_sess=S; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800",
                "gopan_csrf=tok; Path=/; SameSite=Lax; Max-Age=604800",
            ]),
            .init(status: 200, body: #"{"ok":true}"#),
        ])
        let client = DriveClient(baseURLProvider: { self.baseURL }, fetch: stub.fetch)
        let r = try await client.login("tester", "pw")
        XCTAssertEqual(r["user"]["username"].string, "tester")
        XCTAssertEqual(client.authed, true)
        XCTAssertEqual(client.csrf, "tok")

        _ = try await client.mkdir("a", parentId: nil)
        let post = stub.calls[1]
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.headers["x-csrf-token"], "tok")
        XCTAssertEqual(post.headers["cookie"], "gopan_sess=S; gopan_csrf=tok")
        XCTAssertEqual(post.url, "http://127.0.0.1:8787/api/files/folder")
        // GET 不能带 csrf 头
        XCTAssertNil(stub.calls[0].headers["x-csrf-token"])
    }

    func testServerErrorsKeepStatusAndCodeNonJSONRefusedNetworkFriendly() async throws {
        let stub = FetchStub([
            .init(status: 415, body: #"{"error":"该文件不支持预览","code":"preview_unsupported"}"#),
            .init(status: 200, body: "<html>login</html>"),
            .init(error: URLError(.cannotConnectToHost)),
        ])
        let client = DriveClient(baseURLProvider: { self.baseURL }, fetch: stub.fetch)

        do {
            _ = try await client.fileMeta(id: 1)
            XCTFail("should throw")
        } catch let e as ApiError {
            XCTAssertEqual(e.status, 415)
            XCTAssertEqual(e.code, "preview_unsupported")
        }
        do {
            _ = try await client.fileMeta(id: 2)
            XCTFail("should throw")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "bad_json")
        }
        do {
            _ = try await client.me()
            XCTFail("should throw")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "network")
            XCTAssertTrue(e.message.contains("ECONNREFUSED"), "message: \(e.message)")
        }
    }

    func testSwitchingServersDropsOldSessionRestoreWorks() async throws {
        let stub = FetchStub([
            .init(status: 200, body: "{}", setCookie: ["gopan_sess=S; Path=/; Max-Age=604800"]),
        ])
        let client = DriveClient(baseURLProvider: { self.baseURL }, fetch: stub.fetch)
        _ = try await client.me()
        XCTAssertEqual(client.authed, true)

        let jar = client.serializeJar()
        client.resetSession()
        XCTAssertEqual(client.authed, false)
        XCTAssertEqual(client.restoreJar(jar), true)
        XCTAssertNil(client.csrf) // fixture 里没有 csrf cookie
    }

    func testUploadResumeKeyStable() {
        let url = URL(fileURLWithPath: "/tmp/a.zip")
        XCTAssertEqual(UploadManager.resumeKey(localPath: url, size: 123, mtimeMs: 456.4), "/tmp/a.zip|123|456")
        XCTAssertEqual(UploadManager.resumeKey(localPath: url, size: 123, mtimeMs: 456.6), "/tmp/a.zip|123|457")
    }
}
