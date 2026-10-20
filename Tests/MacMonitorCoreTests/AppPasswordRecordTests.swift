import XCTest
@testable import MacMonitorCore

final class AppPasswordRecordTests: XCTestCase {
    func testSaltedVerifierAcceptsOnlyMatchingPasswordAfterRoundTrip() throws {
        let password = "테스트 전용 password 2026"
        let first = try AppPasswordRecord.create(password: password)
        let second = try AppPasswordRecord.create(password: password)
        XCTAssertNotEqual(first.salt, second.salt)
        XCTAssertNotEqual(first.digest, second.digest)
        let restored = try JSONDecoder().decode(AppPasswordRecord.self, from: JSONEncoder().encode(first))
        XCTAssertTrue(try restored.matches(password))
        XCTAssertFalse(try restored.matches("wrong password 2026"))
        XCTAssertFalse(try restored.matches(""))
    }

    func testRejectsWeakInputAndMalformedStoredVerifier() throws {
        XCTAssertThrowsError(try AppPasswordRecord.create(password: "short"))
        XCTAssertThrowsError(try AppPasswordRecord.create(password: String(repeating: "x", count: 1025)))
        let malformed = AppPasswordRecord(salt: Data(), digest: Data(), iterations: 0)
        XCTAssertThrowsError(try malformed.matches("some password"))
    }
}
