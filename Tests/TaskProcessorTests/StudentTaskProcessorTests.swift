import XCTest
@testable import TaskProcessor

@MainActor
final class StudentTaskProcessorTests: XCTestCase {
    func testNegativeMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: -1)) { error in
            XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
        }
    }
}
