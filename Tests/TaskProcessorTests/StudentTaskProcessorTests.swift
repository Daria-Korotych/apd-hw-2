import XCTest
@testable import TaskProcessor

@MainActor
final class StudentTaskProcessorTests: XCTestCase {
    func testNegativeMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: -1)) { error in
            XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
        }
    }

    func testFirstRepeatedIDIsReportedAndNoWorkerRuns() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let log = WorkerLog()

        let error = await errorThrown {
            _ = try await processor.process(makeJobs(["a", "b", "a", "b"]), worker: scriptedWorker(log: log))
        }

        XCTAssertEqual(error as? TaskProcessorError, .duplicateID("a"))
        let startedIDs = await log.startedIDs
        XCTAssertEqual(startedIDs, [])
    }
}
