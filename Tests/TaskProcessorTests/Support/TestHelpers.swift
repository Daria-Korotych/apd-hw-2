@testable import TaskProcessor

enum TestError: Error {
    case expected
}

/// One job per ID. Each job's input is its position, starting at 1: ["a", "b"] gives a = 1, b = 2.
func makeJobs(_ ids: [String]) -> [Job] {
    var jobs: [Job] = []
    for (index, id) in ids.enumerated() {
        jobs.append(Job(id: id, input: index + 1))
    }
    return jobs
}

/// Short way to write the expected array: expectedResults(("a", .succeeded(1)), ("b", .failed)).
func expectedResults(_ pairs: (String, JobOutcome)...) -> [JobResult] {
    var results: [JobResult] = []
    for (id, outcome) in pairs {
        results.append(JobResult(id: id, outcome: outcome))
    }
    return results
}

/// A worker that finishes at once: throws TestError for IDs in `failing`, CancellationError for IDs in `cancelling`, otherwise returns the job's input.
func scriptedWorker(
    failing: Set<String> = [],
    cancelling: Set<String> = [],
    log: WorkerLog = WorkerLog()
) -> @Sendable (Job) async throws -> Int {
    return { job in
        await log.workerStarted(job.id)
        await log.workerFinished()
        if failing.contains(job.id) {
            throw TestError.expected
        }
        if cancelling.contains(job.id) {
            throw CancellationError()
        }
        return job.input
    }
}

/// A retry worker that logs every attempt. It throws TestError until the attempt in `successAttempt[job.id]`, then returns the job's input.
/// A job missing from `successAttempt` fails on every attempt; a job in `cancelling` throws CancellationError.
func retryWorker(
    log: WorkerLog,
    successAttempt: [String: Int] = [:],
    cancelling: Set<String> = []
) -> @Sendable (Job, Int) async throws -> Int {
    return { job, attempt in
        await log.workerStarted(job.id, attempt: attempt)
        await log.workerFinished()
        if cancelling.contains(job.id) {
            throw CancellationError()
        }
        let firstGoodAttempt = successAttempt[job.id] ?? Int.max
        if attempt < firstGoodAttempt {
            throw TestError.expected
        }
        return job.input
    }
}

/// Runs `body` and returns the error it threw, or nil if it finished without throwing.
func errorThrown(by body: @Sendable () async throws -> Void) async -> Error? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}
