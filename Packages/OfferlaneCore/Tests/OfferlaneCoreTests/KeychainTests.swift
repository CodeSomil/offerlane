import XCTest
@testable import OfferlaneCore

final class KeychainTests: XCTestCase {
    let kc = Keychain(service: "com.somilmanke.Offerlane.tests")
    override func tearDown() { kc.deleteAll() }

    func testRoundTripOverwriteDelete() throws {
        try kc.set("one", account: "x"); XCTAssertEqual(kc.get(account: "x"), "one")
        try kc.set("two", account: "x"); XCTAssertEqual(kc.get(account: "x"), "two")
        kc.delete(account: "x"); XCTAssertNil(kc.get(account: "x"))
    }

    func testStrongPassword() {
        let ps = (0..<50).map { _ in Keychain.strongPassword() }
        XCTAssertEqual(Set(ps).count, 50)
        for p in ps {
            XCTAssertEqual(p.count, 18)
            XCTAssertTrue(p.contains(where: \.isLowercase) && p.contains(where: \.isUppercase) && p.contains(where: \.isNumber))
            XCTAssertTrue(p.contains(where: "!@#$%*?".contains))
        }
    }

    func testVaultApprovalIsPerCompany() throws {
        let v = Vault(store: try Store(), keychain: kc)
        let host = "acme.wd5.myworkdayjobs.com"
        XCTAssertFalse(v.isApproved(host: host, company: "Acme"))
        try v.approve(host: host, company: "Acme", email: "me@x.com")
        XCTAssertTrue(v.isApproved(host: host, company: "acme")); XCTAssertFalse(v.isApproved(host: host, company: "Globex"))
        try v.save(host: host, company: "Acme", email: "me@x.com", password: "Pw1!")
        XCTAssertEqual(v.password(host: host), "Pw1!")
        XCTAssertNotNil(try v.store.account(host: host)?.created)
        try v.forget(host: host); XCTAssertNil(v.password(host: host)); XCTAssertNil(try v.store.account(host: host))
    }
}
