import XCTest
@testable import TaskProcessor

@MainActor
final class RetryPolicyTests: XCTestCase {
    func testZeroOrNegativeMaximumAttemptsIsRejected() {
        for badValue in [0, -1] {
            XCTAssertThrowsError(try RetryPolicy(maximumAttempts: badValue)) { error in
                XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
            }
        }
    }

    func testJobSucceedsOnSecondAttempt() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = WorkerLog()

        let results = try await processor.process(
            makeJobs(["flaky"]),
            retryPolicy: RetryPolicy(maximumAttempts: 3),
            worker: retryWorker(log: log, successAttempt: ["flaky": 2])
        )

        XCTAssertEqual(results, expectedResults(("flaky", .succeeded(1))))
        let attempts = await log.attempts
        XCTAssertEqual(attempts["flaky"], [1, 2])
    }

    func testJobFailsAfterLastAttempt() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = WorkerLog()

        let results = try await processor.process(
            makeJobs(["broken"]),
            retryPolicy: RetryPolicy(maximumAttempts: 3),
            worker: retryWorker(log: log)
        )

        XCTAssertEqual(results, expectedResults(("broken", .failed)))
        let attempts = await log.attempts
        XCTAssertEqual(attempts["broken"], [1, 2, 3])
    }

    func testCancellationErrorIsNotRetried() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = WorkerLog()

        let results = try await processor.process(
            makeJobs(["cancels"]),
            retryPolicy: RetryPolicy(maximumAttempts: 3),
            worker: retryWorker(log: log, cancelling: ["cancels"])
        )

        XCTAssertEqual(results, expectedResults(("cancels", .cancelled)))
        let attempts = await log.attempts
        XCTAssertEqual(attempts["cancels"], [1])
    }

    func testRetriesDoNotUseExtraSlots() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = WorkerLog()

        _ = try await processor.process(
            makeJobs(["a", "b"]),
            retryPolicy: RetryPolicy(maximumAttempts: 2),
            worker: retryWorker(log: log, successAttempt: ["a": 2, "b": 2])
        )

        // Job "b" starts only after both attempts of job "a" are done.
        let startedIDs = await log.startedIDs
        XCTAssertEqual(startedIDs, ["a", "a", "b", "b"])
        let peakRunning = await log.peakRunning
        XCTAssertEqual(peakRunning, 1)
    }

    func testRetryResultsKeepInputOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let log = WorkerLog()

        let results = try await processor.process(
            makeJobs(["slow", "medium", "fast"]),
            retryPolicy: RetryPolicy(maximumAttempts: 3),
            worker: retryWorker(log: log, successAttempt: ["slow": 3, "medium": 2, "fast": 1])
        )

        XCTAssertEqual(results, expectedResults(
            ("slow", .succeeded(1)),
            ("medium", .succeeded(2)),
            ("fast", .succeeded(3))
        ))
    }
}
