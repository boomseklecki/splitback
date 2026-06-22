import XCTest
@testable import SplitBackAPI

final class ErrorAlertTests: XCTestCase {
    /// Cancelled requests (navigating away from an in-flight .task) must not surface an alert.
    func testCancellationIsSilent() {
        XCTAssertNil(errorMessage(CancellationError()))
        XCTAssertNil(errorMessage(URLError(.cancelled)))
    }

    /// Real transport failures still show the "can't reach the server" note.
    func testRealTransportFailuresShowUnreachable() {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet,
                     .networkConnectionLost] {
            let message = errorMessage(URLError(code))
            XCTAssertNotNil(message)
            XCTAssertTrue(message?.lowercased().contains("reach") == true, "code \(code)")
        }
    }

    func testBackendErrorKeepsItsMessage() {
        XCTAssertEqual(errorMessage(BackendError.validation("Bad split")), "Bad split")
    }
}
