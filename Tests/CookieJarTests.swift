import XCTest
@testable import gopan

/// 与桌面端 test/unit.test.js 的 cookie jar 用例同源
final class CookieJarTests: XCTestCase {
    func testParsesAttributesHonoursMaxAgeDeletionKeepsCSRF() {
        var jar = CookieJar()
        jar.add(setCookieLines: [
            "gopan_sess=abc123; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800",
            "gopan_csrf=tok%20en; Path=/; SameSite=Lax; Max-Age=604800",
        ])
        XCTAssertEqual(jar.get("gopan_sess"), "abc123")
        XCTAssertEqual(jar.get("gopan_csrf"), "tok%20en")
        XCTAssertTrue(jar.header().contains("gopan_sess=abc123"))

        jar.add(setCookieLines: ["gopan_sess=; Path=/; Max-Age=0"])
        XCTAssertNil(jar.get("gopan_sess"))
        XCTAssertFalse(jar.header().contains("gopan_sess"))

        var round = CookieJar(cookies: jar.toJSON())
        XCTAssertEqual(round.get("gopan_csrf"), "tok%20en")
    }

    func testCookiePastMaxAgeNeverEntersJar() {
        let now = Date()
        var jar = CookieJar()
        jar.add(setCookieLines: ["gopan_sess=fresh; Path=/; Max-Age=100"], now: now)
        XCTAssertEqual(jar.get("gopan_sess"), "fresh")

        jar.add(setCookieLines: ["stale=old; Path=/; Max-Age=-5"], now: now)
        XCTAssertNil(jar.get("stale"))

        // 恢复一个已经过期的会话，同样拒绝发送
        var revived = CookieJar(cookies: [Cookie(name: "gopan_sess", value: "x", expiresAt: now.timeIntervalSince1970 * 1000 - 1000)])
        XCTAssertNil(revived.get("gopan_sess"))
    }

    func testHeaderKeepsInsertionOrder() {
        var jar = CookieJar()
        jar.add(setCookieLines: [
            "gopan_sess=S; Path=/; Max-Age=604800",
            "gopan_csrf=tok; Path=/; Max-Age=604800",
        ])
        XCTAssertEqual(jar.header(), "gopan_sess=S; gopan_csrf=tok")
    }
}
