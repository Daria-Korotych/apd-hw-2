@testable import TaskProcessor

/// A worker the test drives by hand: each job says it has started, then waits until the test releases it.
struct ControlledWorker: Sendable {
    let log = WorkerLog()
    private let ids: [String]
    private let started: SignalSet
    private let released: SignalSet
    private let finished: SignalSet

    init(_ ids: [String]) {
        self.ids = ids
        started = SignalSet(ids)
        released = SignalSet(ids)
        finished = SignalSet(ids)
    }

    /// Runs `process` in the background, so the test can steer the jobs while they run.
    func start(_ jobs: [Job], on processor: TaskProcessor) -> Task<[JobResult], Error> {
        Task {
            try await processor.process(jobs) { job in
                try await run(job)
            }
        }
    }

    func waitUntilStarted(_ ids: String...) async {
        for id in ids {
            await started.wait(id)
        }
    }

    func release(_ id: String) async {
        await released.fire(id)
    }

    /// Releases one job and waits until its worker has returned.
    func finish(_ id: String) async {
        await released.fire(id)
        await finished.wait(id)
    }

    func releaseAll() async {
        for id in ids {
            await released.fire(id)
        }
    }

    private func run(_ job: Job) async throws -> Int {
        await log.workerStarted(job.id)
        await started.fire(job.id)
        await released.wait(job.id)
        await log.workerFinished()
        await finished.fire(job.id)
        // Like a cooperative worker: stop with CancellationError if the caller has cancelled.
        try Task.checkCancellation()
        return job.input
    }
}
