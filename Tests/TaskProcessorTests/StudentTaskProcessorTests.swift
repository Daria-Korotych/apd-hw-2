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

    func testNoMoreThanLimitRunAndFreedSlotStartsNextJob() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let worker = ControlledWorker(["a", "b", "c", "d"])
        let processing = worker.start(makeJobs(["a", "b", "c", "d"]), on: processor)

        await worker.waitUntilStarted("a", "b")
        let startedWhileFull = await worker.log.startedIDs
        XCTAssertEqual(startedWhileFull, ["a", "b"])

        await worker.finish("a")
        await worker.waitUntilStarted("c")
        let startedAfterOneFinished = await worker.log.startedIDs
        XCTAssertEqual(startedAfterOneFinished, ["a", "b", "c"])

        await worker.releaseAll()
        _ = try await processing.value
        let peakRunning = await worker.log.peakRunning
        XCTAssertEqual(peakRunning, 2)
    }

    func testResultsKeepInputOrderWhenJobsFinishInReverse() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let worker = ControlledWorker(["first", "second", "third"])
        let processing = worker.start(makeJobs(["first", "second", "third"]), on: processor)

        await worker.waitUntilStarted("first", "second", "third")
        await worker.finish("third")
        await worker.finish("second")
        await worker.finish("first")

        let results = try await processing.value
        XCTAssertEqual(results, expectedResults(
            ("first", .succeeded(1)),
            ("second", .succeeded(2)),
            ("third", .succeeded(3))
        ))
    }

    func testEachWorkerResultMapsToItsOutcome() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let worker = scriptedWorker(failing: ["fails"], cancelling: ["cancels"])

        let results = try await processor.process(makeJobs(["ok", "fails", "cancels", "okAgain"]), worker: worker)

        XCTAssertEqual(results, expectedResults(
            ("ok", .succeeded(1)),
            ("fails", .failed),
            ("cancels", .cancelled),
            ("okAgain", .succeeded(4))
        ))
    }

    func testWorkerCancellationErrorDoesNotStopLaterJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = WorkerLog()
        let worker = scriptedWorker(cancelling: ["cancelsItself"], log: log)

        let results = try await processor.process(makeJobs(["cancelsItself", "runsAfter"]), worker: worker)

        XCTAssertEqual(results, expectedResults(
            ("cancelsItself", .cancelled),
            ("runsAfter", .succeeded(2))
        ))
        let startedIDs = await log.startedIDs
        XCTAssertEqual(startedIDs, ["cancelsItself", "runsAfter"])
    }

    func testCallerCancellationKeepsFinishedCancelsRunningSkipsQueued() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let worker = ControlledWorker(["done", "running", "queued"])
        let processing = worker.start(makeJobs(["done", "running", "queued"]), on: processor)

        // One slot: "running" starts only after "done" has finished.
        await worker.finish("done")
        await worker.waitUntilStarted("running")
        processing.cancel()
        // Release every job: if "queued" was wrongly started, it must not hang the test.
        await worker.releaseAll()

        let results = try await processing.value
        XCTAssertEqual(results, expectedResults(
            ("done", .succeeded(1)),
            ("running", .cancelled),
            ("queued", .cancelled)
        ))
        let startedIDs = await worker.log.startedIDs
        XCTAssertEqual(startedIDs, ["done", "running"])
    }
}
