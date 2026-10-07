import XCTest
@testable import MacMonitorCore

final class LaunchAtLoginManagerTests: XCTestCase {
    func testLaunchAgentContainsOnlyExpectedExecutableAndRunAtLoad() throws {
        let application = URL(fileURLWithPath: "/Applications/MacMonitor.app")
        let data = try LaunchAtLoginManager.propertyListData(applicationURL: application)
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let propertyList = value as? [String: Any] else {
            return XCTFail("property list is not a dictionary")
        }

        XCTAssertEqual(propertyList["Label"] as? String, LaunchAtLoginManager.label)
        XCTAssertEqual(
            propertyList["ProgramArguments"] as? [String],
            ["/usr/bin/open", "-g", application.path]
        )
        XCTAssertEqual(propertyList["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(propertyList["ProcessType"] as? String, "Background")
    }
}
