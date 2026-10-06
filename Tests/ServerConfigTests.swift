import XCTest
@testable import gopan

/// 与桌面端 test/unit.test.js 的 server urls 用例同源
final class ServerConfigTests: XCTestCase {
    func testLoopbackAndLanHTTPAcceptedSchemelessGetsHTTP() {
        let lb = ServerConfig.parseServerURL("127.0.0.1:8787")
        XCTAssertEqual(lb.ok, true)
        XCTAssertEqual(lb.url, "http://127.0.0.1:8787")
        XCTAssertEqual(lb.scope, .loopback)
        XCTAssertEqual(lb.needsAck, false)

        let lan = ServerConfig.parseServerURL("http://192.168.1.7:8787/")
        XCTAssertEqual(lan.ok, true)
        XCTAssertEqual(lan.scope, .privateScope)

        let https = ServerConfig.parseServerURL("https://drive.example.com")
        XCTAssertEqual(https.ok, true)
        XCTAssertEqual(https.secure, true)
    }

    func testPlaintextToPublicHostNeedsExplicitAck() {
        let r = ServerConfig.parseServerURL("http://drive.example.com")
        XCTAssertEqual(r.ok, true)
        XCTAssertEqual(r.scope, .publicScope)
        XCTAssertEqual(r.needsAck, true)
    }

    func testJunkAndCredentialSmugglingRefused() {
        for bad in ["", "   ", "file:///C:/Windows", "javascript:alert(1)", "http://a:b@evil.com", "http://evil.com/api/files"] {
            XCTAssertFalse(ServerConfig.parseServerURL(bad).ok, "must refuse \(bad)")
        }
        XCTAssertEqual(ServerConfig.parseServerURL("http://u:p@evil.com").reason, "地址里不能带账号密码")
    }

    func testDefaultServerIsLoopback() {
        XCTAssertEqual(ServerConfig.defaultServerURL, "http://127.0.0.1:8787")
    }
}
