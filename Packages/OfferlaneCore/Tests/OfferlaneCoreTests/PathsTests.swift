import XCTest
@testable import OfferlaneCore

final class PathsTests: XCTestCase {
    func testOverrideRoot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("OFFERLANE_HOME", tmp.path, 1); defer { unsetenv("OFFERLANE_HOME") }
        try Paths.ensure()
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.applications.path))
    }
}
