/// Throws for the first job, in input order, whose ID was already used by an earlier job.
func checkForDuplicateIDs(_ jobs: [Job]) throws {
    var seenIDs: Set<String> = []
    for job in jobs {
        if seenIDs.contains(job.id) {
            throw TaskProcessorError.duplicateID(job.id)
        }
        seenIDs.insert(job.id)
    }
}

/// Runs every job, never more than `maximumConcurrency` at once, and returns results in input order.
func runJobs(
    _ jobs: [Job],
    maximumConcurrency: Int,
    maximumAttempts: Int,
    worker: @escaping @Sendable (Job, Int) async throws -> Int
) async -> [JobResult] {
    // One slot per job. A slot stays nil if its job never started.
    var outcomes: [JobOutcome?] = Array(repeating: nil, count: jobs.count)

    // Non-throwing group: runJob catches every worker error, so one failing job cannot stop the others.
    await withTaskGroup(of: (Int, JobOutcome).self) { group in
        var nextIndex = 0
        var runningCount = 0

        while true {
            // Fill every free slot, left to right, unless the caller has cancelled.
            while runningCount < maximumConcurrency
                && nextIndex < jobs.count
                && !Task.isCancelled {
                let index = nextIndex
                let job = jobs[index]
                group.addTask {
                    let outcome = await runJob(job, maximumAttempts: maximumAttempts, worker: worker)
                    return (index, outcome)
                }
                nextIndex += 1
                runningCount += 1
            }

            // Wait for any one job to finish; nil means nothing is running any more.
            guard let (index, outcome) = await group.next() else {
                break
            }
            outcomes[index] = outcome
            runningCount -= 1
        }
    }

    var results: [JobResult] = []
    for (index, job) in jobs.enumerated() {
        // A job with no outcome was never started because the caller cancelled.
        let outcome = outcomes[index] ?? .cancelled
        results.append(JobResult(id: job.id, outcome: outcome))
    }
    return results
}

/// Calls the worker for one job and turns its result or error into a JobOutcome.
func runJob(
    _ job: Job,
    maximumAttempts: Int,
    worker: @Sendable (Job, Int) async throws -> Int
) async -> JobOutcome {
    do {
        let value = try await worker(job, 1)
        return .succeeded(value)
    } catch is CancellationError {
        return .cancelled
    } catch {
        return .failed
    }
}
