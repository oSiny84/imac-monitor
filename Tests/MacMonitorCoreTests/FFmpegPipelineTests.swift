import Darwin
import Foundation
import XCTest
@testable import MacMonitorCore

final class FFmpegPipelineTests: XCTestCase {
    func testClosedEncoderPipeReportsEPIPEInsteadOfTerminatingMonitoring() throws {
        let pipe = try FFmpegPipeline.makeInputPipe()
        defer { try? pipe.fileHandleForWriting.close() }
        // Check before writing so a broken implementation cannot kill the test runner.
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1 else {
            XCTFail("encoder input must suppress SIGPIPE on its own file descriptor")
            return
        }
        try pipe.fileHandleForReading.close()
        var byte: UInt8 = 0
        let result = Darwin.write(pipe.fileHandleForWriting.fileDescriptor, &byte, 1)
        let code = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(code, EPIPE)
    }
}
