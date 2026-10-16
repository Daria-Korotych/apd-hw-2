# Implementation Plan

Complete this before implementation and update it when the plan changes.

## Approach

One function, `runJobs`, runs every job inside a non-throwing task group. It loops: start jobs left to right while fewer than `maximumConcurrency` are running, then wait for any one job to finish, store its outcome at that job's index, and repeat. Because each outcome is stored by index, results come back in input order no matter which job finishes first. `runJob` calls the worker and turns its value, ordinary error, or `CancellationError` into `.succeeded`, `.failed`, or `.cancelled`, so no error escapes a child task and one failing job cannot stop the others. When the caller cancels, `Task.isCancelled` stops new jobs from starting, the task group cancels the running ones, and jobs that never started are reported as `.cancelled`. Duplicate IDs are rejected by a left-to-right scan before any job starts. The retry extension reuses `runJobs` with a higher attempt limit; the attempts for one job run one after another inside that job's slot, so a retry never takes an extra slot.

Code layout: `TaskProcessor.swift` (public types, actor, base `process`), `Scheduler.swift` (`checkForDuplicateIDs`, `runJobs`, `runJob`), `RetryPolicy.swift` (retry API). Tests: `StudentTaskProcessorTests.swift` (7 base tests), `RetryPolicyTests.swift` (6 retry tests), helpers in `Tests/TaskProcessorTests/Support/`.

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.

## Risks and checks

- Timing-dependent tests would be flaky: tests control order with `ControlledWorker` (built on a small `Signal` actor), never with sleeps or time checks.
- Concurrency limit: `WorkerLog` tracks the peak number of running workers; the scheduling test asserts it equals the limit and that job `c` starts only after a slot frees.
- Cancellation race: the cancellation test uses one slot, so which job is done, running and queued is fixed before cancelling. It releases every job after cancelling, so a wrongly started job makes the test fail instead of hang.
- Duplicate IDs: the first repeated ID in input order is reported, and an empty worker log proves no worker ran.
- Retries inside one slot: a one-slot test asserts the start order `a, a, b, b` and a peak of 1.
- Cancelling between retry attempts ends the job as `.cancelled` without another worker call, following the base rule that no new worker starts after cancellation.
- Strict concurrency: `swift build --build-tests -Xswiftc -warnings-as-errors` must pass with zero warnings.
