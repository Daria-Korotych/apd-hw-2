public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        if maximumAttempts <= 0 {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }
        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        try checkForDuplicateIDs(jobs)
        return await runJobs(
            jobs,
            maximumConcurrency: maximumConcurrency,
            maximumAttempts: retryPolicy.maximumAttempts,
            worker: worker
        )
    }
}
