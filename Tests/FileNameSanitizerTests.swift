import XCTest
@testable import gopan

/// 与桌面端 test/unit.test.js 的 local names / mime map 用例同源
final class FileNameSanitizerTests: XCTestCase {
    func testTraversalSeparatorsReservedDevicesAndLength() {
        XCTAssertEqual(FileNameSanitizer.sanitizeName("../../windows/system32/x"), "windows system32 x")
        XCTAssertEqual(FileNameSanitizer.sanitizeName("a\\b/c"), "a b c")
        XCTAssertEqual(FileNameSanitizer.sanitizeName("CON.txt"), "_CON.txt")
        XCTAssertEqual(FileNameSanitizer.sanitizeName("nul"), "_nul")
        XCTAssertEqual(FileNameSanitizer.sanitizeName("   "), "file")
        XCTAssertEqual(FileNameSanitizer.sanitizeName("."), "file")
        XCTAssertLessThanOrEqual(FileNameSanitizer.sanitizeName(String(repeating: "x", count: 400)).count, 130)
        XCTAssertFalse(FileNameSanitizer.sanitizeName("a<b>c:d|e?f*g\"").range(of: "[<>:\"|?*]", options: .regularExpression) != nil)
        XCTAssertFalse(FileNameSanitizer.sanitizeName("be\u{00}llo").range(of: "[\\x00-\\x1f]", options: .regularExpression) != nil)
    }

    func testExistingTargetsGetCounterInsteadOfOverwrite() {
        let dir = URL(fileURLWithPath: "/tmp/bonfire-fixture")
        let taken: Set<String> = ["a.png", "a (2).png"]
        let result = FileNameSanitizer.uniqueLocalName(in: dir, name: "a.png") { url in
            taken.contains(url.lastPathComponent)
        }
        XCTAssertEqual(result, "a (3).png")

        let fresh = FileNameSanitizer.uniqueLocalName(in: dir, name: "new.png") { _ in false }
        XCTAssertEqual(fresh, "new.png")
    }

    func testMimeMap() {
        XCTAssertEqual(MimeTypes.mimeFor("a.PNG"), "image/png")
        XCTAssertEqual(MimeTypes.mimeFor("noext"), "application/octet-stream")
        XCTAssertEqual(MimeTypes.mimeFor("a.exe"), "application/octet-stream")
    }
}
