# HW2 Task Processor — Design

Scope: base assignment (12 pts) plus the optional retry extension (+4). The binding contract is `TASKS_AND_GRADES.md`; this spec decides *how*, never *what*. Where the two disagree, the contract wins.

## Goals

- Pass every published rule with deterministic tests (no sleeps, no timing assertions).
- One place for the hard logic: bounded scheduling, input-order storage and cancellation are written once and shared by base and retry.
- Public signatures unchanged from the starter.
- Standard library + XCTest only. No GCD, no locks, no unstructured `Task` inside the library.

## Architecture (approach A: shared scheduler core)

```
process(jobs, worker)                    process(jobs, retryPolicy, worker)
        │                                          │
        │  runJob = single attempt                 │  runJob = attempt loop 1...maximumAttempts
        └──────────────┬───────────────────────────┘
                       ▼
        validateUniqueIDs(jobs)   — throws .duplicateID before any worker
                       ▼
        runBounded(jobs, limit, runJob) — task group, N slots, index-keyed results, cancellation
                       ▼
                 [JobResult] in input order
```

### Units

| File | Unit | Does | Depends on |
| --- | --- | --- | --- |
| `Sources/TaskProcessor/TaskProcessor.swift` | public types, `TaskProcessor` actor, base `process` | keeps starter signatures; `init` validates capacity; base `process` = validate IDs + `runBounded` with a single-attempt `runJob` | `BoundedScheduler.swift`, `JobOutcome+Worker.swift` |
| `Sources/TaskProcessor/BoundedScheduler.swift` | `validateUniqueIDs(_:)`, `runBounded(_:maximumConcurrency:runJob:)` | preflight duplicate scan; bounded, cancellation-aware scheduling | nothing but the public types |
| `Sources/TaskProcessor/JobOutcome+Worker.swift` | `JobOutcome.init(running:)` (async) | maps one worker call to `.succeeded` / `.failed` / `.cancelled` | nothing |
| `Sources/TaskProcessor/RetryPolicy.swift` | `RetryPolicy`, `RetryPolicyError`, retry `process` extension | validates attempts; attempt loop as `runJob` | scheduler + outcome mapping |

All helpers are `internal` (visible to `@testable` tests, invisible to graders' public API check).

## Data flow and rules

### Configuration

`TaskProcessor.init(maximumConcurrency:)` throws `.nonPositiveMaximumConcurrency` when the value is `<= 0`; otherwise stores it.

### Duplicate IDs (preflight)

`validateUniqueIDs` walks `jobs` left to right with a `Set<String>` of seen IDs. The first job whose ID is already in the set throws `.duplicateID(id)`. It runs before `runBounded`, so no worker can start. IDs are compared exactly (no normalization — a contract non-goal).

### Empty input

`runBounded` returns `[]` immediately when `jobs` is empty; no group is created, no worker runs.

### Bounded scheduling

Inside a non-throwing `withTaskGroup(of: (index: Int, outcome: JobOutcome).self)`:

1. `results: [JobOutcome?]` sized to `jobs.count`, all `nil`.
2. `nextIndex = 0`. A local `startNextIfAllowed()` adds a child for `jobs[nextIndex]` and increments, **only if** `nextIndex < jobs.count` and `!Task.isCancelled`.
3. Start `min(maximumConcurrency, jobs.count)` children via `startNextIfAllowed()` — left to right.
4. Loop `while let (index, outcome) = await group.next()`: store `results[index] = outcome`, then call `startNextIfAllowed()` once. One finished child frees exactly one slot, so at most `maximumConcurrency` children exist at any moment.
5. After the group drains, map `results` to `JobResult(id: jobs[i].id, outcome: results[i] ?? .cancelled)`.

Why `withTaskGroup`, not `withThrowingTaskGroup`: no child ever throws. Each child turns its worker's error into a `JobOutcome` (see Outcome mapping), because the contract needs one result per job and requires the other jobs to keep running after an error. With a throwing group, `group.next()` would be `try await` for errors that can never happen. Worse, a single `try` that let an error escape the group body would cancel all siblings and lose the results already collected. Typing the group as non-throwing makes "a worker error cannot stop the batch" something the compiler enforces, not something we have to remember. The only errors `process` throws (`.duplicateID`) are raised before the group exists. The POC used this exact form.

`nil` after drain can only mean "never started because cancellation was observed", which the contract maps to `.cancelled`.

Each child returns its own index, so completion order never affects output order.

### Outcome mapping

`JobOutcome.init(running work: () async throws -> Int) async`:

- returns a value → `.succeeded(value)`
- throws `CancellationError` → `.cancelled`
- throws anything else → `.failed`

Errors never escape a child, which is why the group is non-throwing and one failing job cannot tear down the others.

### Caller cancellation

- Swift propagates the caller's cancellation into the task group, which cancels every running child. Cooperative workers throw `CancellationError` → `.cancelled`.
- Each scheduling decision (step 2 above) checks `Task.isCancelled`; once true, no new child is added. Remaining queued jobs stay `nil` → `.cancelled`.
- Children that already returned before cancellation keep their stored outcome; the drain loop still collects them.
- A worker that ignores cancellation and returns a value is recorded as `.succeeded` — the contract does not promise anything stronger.
- `process` itself does not throw on cancellation; it returns the full result array. (The contract describes results, not a thrown error.)

### Retry extension

`RetryPolicy.init(maximumAttempts:)` throws `.nonPositiveMaximumAttempts` when `<= 0`.

Retry `process` = `validateUniqueIDs` + `runBounded` with this `runJob`:

```
for attempt in 1...maximumAttempts:
    if attempt > 1 and Task.isCancelled → return .cancelled
    outcome = JobOutcome(running: { try await worker(job, attempt) })
    if outcome != .failed or attempt == maximumAttempts → return outcome
```

- Attempts run sequentially inside the job's single child, so retries never use an extra slot.
- `CancellationError` returns `.cancelled` at once and is never retried.
- No delay, backoff or randomness.
- Decision: if cancellation is observed between attempts, the job ends `.cancelled` without starting another attempt. Reason: the base rule "starts no new worker after cancellation is observed" applies to every worker call, and the job had not reached a final result yet.

## Error handling summary

| Source | Where handled | Result |
| --- | --- | --- |
| capacity `<= 0` | `init` | throws `.nonPositiveMaximumConcurrency` |
| attempts `<= 0` | `RetryPolicy.init` | throws `.nonPositiveMaximumAttempts` |
| repeated ID | `validateUniqueIDs` | throws `.duplicateID(first)`; zero workers ran |
| worker ordinary error | outcome mapping | `.failed` (after last attempt, in retry) |
| worker `CancellationError` | outcome mapping | `.cancelled`, never retried |
| caller cancels | scheduler | no new starts; unstarted → `.cancelled` |

## Testing

Deterministic only: gates and probes, never `sleep` or elapsed-time checks. Test helpers live in `Tests/TaskProcessorTests/Support/` (a copy of the starter's `Gate`, plus `ConcurrencyProbe` actor tracking current/peak active count and an invocation log). Helpers do not count toward the six required tests.

### `StudentTaskProcessorTests.swift` (base, counts toward the required 6)

1. `testNegativeMaximumConcurrencyIsRejected`
2. `testFirstRepeatedIDIsReportedAndNoWorkerRuns` — `[a, b, a, b]` → `.duplicateID("a")`, probe log empty.
3. `testActiveWorkersNeverExceedLimitAndFreedSlotStartsNextJob` — limit 2, 4 gated jobs; peak == 2; job 3 starts only after release of job 1.
4. `testResultsFollowInputOrderForReverseCompletion` — 3 jobs released in reverse order.
5. `testMixedOutcomesAreMappedAndOtherJobsContinue` — success, ordinary error, `CancellationError` in one call.
6. `testWorkerCancellationErrorDoesNotStopLaterJobs` — limit 1; job 1 throws `CancellationError`, job 2 still runs.
7. `testCallerCancellationKeepsFinishedSkipsQueuedAndCancelsRunning` — limit 1, jobs `[done, running, queued]`: `done` succeeds, `running` waits at gate then checks cancellation, test cancels then releases; expect `[succeeded, cancelled, cancelled]` and log shows `queued` never invoked.

### `RetryPolicyTests.swift` (bonus)

1. `testNonPositiveMaximumAttemptsIsRejected`
2. `testJobRecoversBeforeLimitWithExactAttemptNumbers` — fails on 1, succeeds on 2; log `[1, 2]`.
3. `testFinalOrdinaryErrorYieldsFailedAfterMaximumAttempts` — log `[1, 2, 3]` for max 3.
4. `testCancellationErrorIsNotRetried` — log `[1]`, outcome `.cancelled`.
5. `testRetriesStayInsideOneConcurrencySlot` — limit 1, two jobs both retrying; peak active == 1.
6. `testRetryResultsKeepInputOrder`

### Verification

`swift test` is the only required command. Additionally run `swift build -Xswiftc -warnings-as-errors` once to prove zero concurrency warnings.

## Repository evidence (non-code)

- `PLAN.md`: filled from this spec (approach, milestones ticked, risks).
- `AGENT_WORKLOG.md`: one row per agent-assisted step (Claude Code, Opus 5.5); the review column is written by the student after reading each diff.
- No `artifacts/` required.

## Risks

| Risk | Check |
| --- | --- |
| Cancellation race: child finishes the instant cancel arrives | Test 7 sequences it with gates, so the order is fixed; contract only grades "completed before observed". |
| Capturing the task group inside a local function trips Swift 6 checks | POC compiled it warning-free (below). |
| Private graders combine cases (e.g. retry + cancel) | Shared core means every base rule applies to retry by construction. |
| Overlapping `process` calls on one actor | Not graded; each call owns its own group and counters, no shared mutable state. |

## Prototype results

Throwaway package in the session scratchpad (deleted after this spec), Swift 6.4 / tools 6.0, macOS:

- `swift build -Xswiftc -warnings-as-errors` → `Build complete!`. Actor method + `withTaskGroup` + local function calling `group.addTask` with an `@Sendable` worker compiles with zero strict-concurrency diagnostics.
- Cancel test, limit 2, inputs `[1, 2, 3, 4]`, job 1 returns immediately, others sleep cooperatively, caller cancels → `[ok(10), cancelled, cancelled, cancelled]`. Confirms: group still drains after cancellation, completed result kept, running cooperative child cancelled, unstarted jobs never invoked.
- The POC test used `Task.sleep` to order events; the real tests replace that with gates.
