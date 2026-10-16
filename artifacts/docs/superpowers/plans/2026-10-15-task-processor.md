# HW2 Task Processor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the bounded concurrent `TaskProcessor` (base, 12 pts) and the retry extension (+4) so that `swift test` passes with at least six student-authored tests.

**Architecture:** One function, `runJobs`, does all the scheduling: it keeps at most N jobs running, starts the next job when one finishes, stores each outcome at its job's index, and stops starting jobs when the caller cancels. A second function, `runJob`, calls the worker for one job and turns its result or error into a `JobOutcome`. The base `process` and the retry `process` both call `runJobs`; the base one simply allows one attempt.

**Tech Stack:** Swift 6 (toolchain 6.4, `swift-tools-version: 6.0`), Swift standard library, XCTest.

**Audience:** written for a trainee new to Swift. Every task explains the Swift features it uses before showing the code. Type the code yourself rather than pasting it; the explanations tell you what each part is for.

Spec: `artifacts/docs/superpowers/specs/2026-10-15-task-processor-design.md`. Contract: `TASKS_AND_GRADES.md` (wins on conflict).

**Verified:** the final code of this plan was built and run in a scratch copy before writing it down: `swift build --build-tests -Xswiftc -warnings-as-errors` → `Build complete!`; `swift test` → `Executed 18 tests, with 0 failures`, 5 runs out of 5. With the cancellation check removed, exactly one test fails (`Executed 18 tests, with 1 failure`), as Task 4 expects, and nothing hangs.

## Differences from the spec

Same behaviour, simpler code for a first Swift project:

- 3 source files instead of 4. `JobOutcome.init(running:)` is replaced by a plain function `runJob(_:maximumAttempts:worker:)`, and the scheduler is named `runJobs`.
- `runJobs` always takes a two-argument worker `(Job, Int)` (the `Int` is the attempt number). The base `process` passes `maximumAttempts: 1` and wraps its one-argument worker. Retry then needs no second scheduler.
- The scheduler is one readable loop ("fill free slots, wait for one job to finish, repeat") with an explicit `runningCount`, instead of a nested helper function.
- Test helpers: the starter's 4-method `Gate` is replaced by a tiny `Signal` (a one-time "go" flag) and `SignalSet` (one `Signal` per job name). `ConcurrencyProbe` and `AttemptLog` merge into one `WorkerLog`. Small helpers (`ControlledWorker`, `makeJobs`, `expectedResults`, `scriptedWorker`, `retryWorker`, `errorThrown`) keep every test method short: each test only says what is special about its case.

## Global Constraints

- Public API names, access levels, argument labels, conformances and return types stay exactly as in `TASKS_AND_GRADES.md`.
- Standard library and XCTest only. No GCD, no locks, no `Task { }` inside `Sources/`.
- Tests are deterministic: signals only, no `sleep`, no time checks, no randomness, no `print`.
- Do not modify `Tests/TaskProcessorTests/TaskProcessorPublicTests.swift` (starter tests).
- Required verification: `swift test`. Also once at the end: `swift build --build-tests -Xswiftc -warnings-as-errors`.
- Commits: Conventional Commits, no AI attribution. Work on branch `feat/task-processor`, merge to `main` through a PR.

## Swift basics you need first (read once, ~15 min)

| Concept | What it means here |
| --- | --- |
| `struct`, `enum` | Value types. `Job` and `JobResult` are structs (a bundle of fields); `JobOutcome` is an enum (exactly one of `succeeded(Int)`, `failed`, `cancelled`). |
| `throws` / `try` / `do`–`catch` | A function marked `throws` can fail with an error. You call it with `try`. `do { try … } catch { … }` handles the error. `catch is CancellationError` catches only that one error type. |
| `async` / `await` | An `async` function can pause while it waits (for another job, a signal…). You call it with `await`. While it is paused, the thread does other work. |
| `Task { … }` | Starts async work in the background and gives you a handle. `task.value` waits for its result; `task.cancel()` asks it to stop. Used only in tests. |
| Cancellation | Swift cancellation is a request, not a kill. `Task.isCancelled` reads the flag. `try Task.checkCancellation()` throws `CancellationError` if the flag is set. Workers that check it are called "cooperative". |
| Task group | `withTaskGroup(of: T.self) { group in … }` lets you start child tasks with `group.addTask { … }` and collect their results one by one with `await group.next()`, which returns `nil` when no child is left. When the parent is cancelled, every child is cancelled too. |
| `actor` | A class whose properties can be touched by only one task at a time, so parallel tasks cannot corrupt it. Calls into an actor from outside need `await`. `TaskProcessor` is an actor; the test helpers are actors too. |
| `Sendable` / `@Sendable` | "Safe to share between parallel tasks". Swift 6 checks this at compile time. The worker closure is `@Sendable` because many child tasks call it at once. |
| `@escaping` | The closure is stored or used after the function returns (here: inside child tasks). |
| Closures | Inline functions: `{ job in job.input * 2 }`. `{ job, _ in … }` ignores the second argument. A trailing closure is written after the `)` of a call. |
| Optionals | `JobOutcome?` means "a `JobOutcome` or `nil`". `value ?? fallback` uses `fallback` when `value` is `nil`. |
| `CheckedContinuation` | A way to pause an async function until some other code calls `continuation.resume()`. Used only in `Signal`. |
| XCTest | Each `func testSomething()` in a class inheriting `XCTestCase` is one test. `XCTAssertEqual(a, b)` fails the test if `a != b`. Async tests are `async throws`. `@MainActor` on the class matches the starter test file. |
| `@testable import` | Lets tests see `internal` (non-`public`) functions such as `runJobs`. |

Useful commands:

- Run one test: `swift test --filter StudentTaskProcessorTests/testNegativeMaximumConcurrencyIsRejected`
- Run everything: `swift test`

Until Task 3 is finished, the starter `process` still calls `fatalError`, so always use `--filter` until then. A bare `swift test` crashes inside the starter tests.

## File map

| File | Responsibility | Task |
| --- | --- | --- |
| `Tests/TaskProcessorTests/Support/Signal.swift` | `Signal`, `SignalSet`: let a test pause and release workers by name | 1 |
| `Tests/TaskProcessorTests/Support/WorkerLog.swift` | `WorkerLog`: records started jobs, attempts, peak running count | 1 |
| `Tests/TaskProcessorTests/Support/ControlledWorker.swift` | `ControlledWorker`: a worker the test pauses and releases by job name | 1 |
| `Tests/TaskProcessorTests/Support/TestHelpers.swift` | `TestError`, `makeJobs`, `expectedResults`, `scriptedWorker`, `retryWorker`, `errorThrown` | 1 |
| `Tests/TaskProcessorTests/StudentTaskProcessorTests.swift` | 7 base tests | 1–4 |
| `Sources/TaskProcessor/TaskProcessor.swift` | public types (unchanged), actor `init`, base `process` | 1–3 |
| `Sources/TaskProcessor/Scheduler.swift` | `checkForDuplicateIDs`, `runJobs`, `runJob` | 2–5 |
| `Sources/TaskProcessor/RetryPolicy.swift` | retry API | 5 |
| `Tests/TaskProcessorTests/RetryPolicyTests.swift` | 6 retry tests | 5 |
| `PLAN.md`, `AGENT_WORKLOG.md` | submission evidence | 6 |

---

### Task 1: Test helpers and capacity validation (~35 min)

**Files:**
- Create: `Tests/TaskProcessorTests/Support/Signal.swift`
- Create: `Tests/TaskProcessorTests/Support/WorkerLog.swift`
- Create: `Tests/TaskProcessorTests/Support/ControlledWorker.swift`
- Create: `Tests/TaskProcessorTests/Support/TestHelpers.swift`
- Create: `Tests/TaskProcessorTests/StudentTaskProcessorTests.swift`
- Modify: `Sources/TaskProcessor/TaskProcessor.swift` (only the `TaskProcessor` actor)

**Interfaces:**
- Produces: `actor Signal` with `fire()`, `wait() async`; `struct SignalSet` with `init(_ ids: [String])`, `fire(_ id:) async`, `wait(_ id:) async`; `actor WorkerLog` with `workerStarted(_ id: String, attempt: Int = 1)`, `workerFinished()`, `startedIDs: [String]`, `attempts: [String: [Int]]`, `peakRunning: Int`; `struct ControlledWorker` with `init(_ ids: [String])`, `log: WorkerLog`, `start(_ jobs: [Job], on processor: TaskProcessor) -> Task<[JobResult], Error>`, `waitUntilStarted(_ ids: String...) async`, `release(_ id:) async`, `finish(_ id:) async`, `releaseAll() async`; `enum TestError: Error { case expected }`; `func makeJobs(_ ids: [String]) -> [Job]`; `func expectedResults(_ pairs: (String, JobOutcome)...) -> [JobResult]`; `func scriptedWorker(failing: Set<String> = [], cancelling: Set<String> = [], log: WorkerLog = WorkerLog()) -> @Sendable (Job) async throws -> Int`; `func retryWorker(log: WorkerLog, successAttempt: [String: Int] = [:], cancelling: Set<String> = []) -> @Sendable (Job, Int) async throws -> Int`; `func errorThrown(by body: @Sendable () async throws -> Void) async -> Error?`; internal stored property `let maximumConcurrency: Int` on `TaskProcessor`.

- [ ] **Step 1: Move to the implementation branch**

```bash
cd ~/Documents/KSE/APD/labs/apd-hw-2
git switch docs/hw2-spec
git branch -m feat/task-processor
```

- [ ] **Step 2: Create `Tests/TaskProcessorTests/Support/Signal.swift`**

Why: tests must control *when* each worker finishes, without `sleep`. A `Signal` is a one-time "go" flag. A worker calls `await signal.wait()` and stays paused until the test calls `await signal.fire()`. It is an `actor` because the test and many workers use it at the same time.

How `wait()` works: if the signal already fired, return at once. Otherwise `withCheckedContinuation` pauses this function and hands us a `continuation` (think: a "resume button"). We store that button in `waiters`. Later, `fire()` presses every stored button with `resume()`, and each paused `wait()` continues from where it stopped. There is no gap between the `isFired` check and storing the button, because code inside an actor runs without interruption until it reaches an `await`.

`SignalSet` is a dictionary of signals keyed by job ID, so `ControlledWorker` (Step 4) can write `await started.wait("a")` or `await released.fire("b")`. Tests never use signals directly. It is a `struct` holding only actors, so it is `Sendable` and workers may capture it.

```swift
/// A one-time "go" flag that async code can wait for.
///
/// Before `fire()` is called, `wait()` pauses. After it, every waiter continues and later `wait()` calls return at once.
actor Signal {
    private var isFired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        isFired = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if isFired {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// One `Signal` per job ID, so a test can say "job a started" or "let job b finish" by name.
struct SignalSet: Sendable {
    private let signals: [String: Signal]

    init(_ ids: [String]) {
        var signals: [String: Signal] = [:]
        for id in ids {
            signals[id] = Signal()
        }
        self.signals = signals
    }

    func fire(_ id: String) async {
        await signals[id]?.fire()
    }

    func wait(_ id: String) async {
        await signals[id]?.wait()
    }
}
```

- [ ] **Step 3: Create `Tests/TaskProcessorTests/Support/WorkerLog.swift`**

Why: tests need to prove things like "job c never started" or "never more than 2 ran at once". Workers call `workerStarted` when they begin and `workerFinished` when they end.

Two different things are tracked, and it is important not to mix them up:

- `startedIDs` is a **history**: every start is appended and nothing is ever removed. A test reads it afterwards to check *who started, in what order*, for example `["done", "running"]` proves `queued` never started. That is why `workerFinished()` does not touch it; removing IDs would erase the evidence.
- `running` is the **current** number of workers inside their work. `workerStarted` adds 1, `workerFinished` subtracts 1, and `peakRunning` remembers the highest value it ever had. `workerFinished()` needs no ID because only the count matters.

`private(set)` means tests can read the value but only the log itself can change it. `attempts[id, default: []].append(attempt)` means "take the list for this ID, or an empty list if there is none, and append".

```swift
/// Records what workers did, so a test can check it afterwards.
actor WorkerLog {
    /// Every start, in order. Never shrinks: it is a history, not the list of jobs running now.
    private(set) var startedIDs: [String] = []
    /// Attempt numbers per job ID, in order, e.g. ["flaky": [1, 2]].
    private(set) var attempts: [String: [Int]] = [:]
    /// The highest value `running` ever reached.
    private(set) var peakRunning = 0
    /// How many workers are running right now.
    private var running = 0

    func workerStarted(_ id: String, attempt: Int = 1) {
        startedIDs.append(id)
        attempts[id, default: []].append(attempt)
        running += 1
        peakRunning = max(peakRunning, running)
    }

    func workerFinished() {
        running -= 1
    }
}
```

- [ ] **Step 4: Create `Tests/TaskProcessorTests/Support/ControlledWorker.swift`**

Why: several tests need workers that pause until the test lets them finish. Instead of repeating that setup in every test, `ControlledWorker` packs it into one object with readable methods:

- `start(jobs, on: processor)` runs `process` in the background (`Task { … }`) and returns the task, so the test keeps going while the jobs are paused. `try await processing.value` later waits for the final results; `processing.cancel()` cancels it.
- `waitUntilStarted("a", "b")` pauses the test until those workers are running. `String...` means "any number of strings", which arrive as an array.
- `release("a")` lets job `a` continue; `finish("a")` lets it continue *and* waits until its worker has returned; `releaseAll()` lets every job continue.

Inside, every job runs `run(job)`: log the start, fire `started`, wait for `released`, log the finish, fire `finished`, then `try Task.checkCancellation()`. That last line makes it a *cooperative* worker: if the caller cancelled, it throws `CancellationError` instead of returning. The struct holds only actors and `let` values, so it is `Sendable` and the background task may use it. Each Swift file needs its own imports, so this file starts with `@testable import TaskProcessor`.

```swift
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
```

- [ ] **Step 5: Create `Tests/TaskProcessorTests/Support/TestHelpers.swift`**

Small functions that keep each test method to a few lines:

- `makeJobs(["a", "b"])` builds the job array. Inputs are positions (`a` = 1, `b` = 2), so with a worker that returns its input you know every expected value without looking it up.
- `expectedResults(("a", .succeeded(1)), ("b", .failed))` builds the expected `[JobResult]`. `(String, JobOutcome)...` means "any number of (ID, outcome) pairs".
- `scriptedWorker(failing:cancelling:log:)` returns a worker closure that finishes at once: it throws `TestError` for IDs in `failing`, `CancellationError` for IDs in `cancelling`, and otherwise returns the job's input. The return type `@Sendable (Job) async throws -> Int` is exactly the type `process` expects for `worker:`. Default arguments (`= []`) mean you only pass what a test needs.
- `retryWorker(log:successAttempt:cancelling:)` is the same idea for retries: it logs each attempt and keeps throwing `TestError` until the attempt number in `successAttempt[job.id]`. A job missing from that dictionary uses `Int.max`, so it never succeeds.
- `errorThrown { … }` runs the code in braces and returns the error it threw, or `nil`. Its parameter is `@Sendable` because Swift 6 refuses to hand a non-`Sendable` closure to another async function (compiler error: `sending value of non-Sendable type … risks causing data races`).

```swift
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
```

- [ ] **Step 6: Write the first failing test in `Tests/TaskProcessorTests/StudentTaskProcessorTests.swift`**

`XCTAssertThrowsError(expression) { error in … }` passes only if the expression throws; the closure then checks *which* error. `error as? TaskProcessorError` converts the general `Error` to our enum (or `nil` if it is a different type).

```swift
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
```

- [ ] **Step 7: Run it to verify it fails**

Run: `swift test --filter StudentTaskProcessorTests/testNegativeMaximumConcurrencyIsRejected`
Expected: crash with `Fatal error: Implement Homework 2` (the starter `init` is still a stub).

- [ ] **Step 8: Implement `init` in `Sources/TaskProcessor/TaskProcessor.swift`**

Replace only the `TaskProcessor` actor at the bottom of the file; keep `Job`, `JobOutcome`, `JobResult` and `TaskProcessorError` exactly as they are. `let maximumConcurrency` has no `public` or `private`, so it is `internal`: visible inside the package (Task 5 needs it) but not to users of the library. `process` stays a stub for now.

```swift
public actor TaskProcessor {
    let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        if maximumConcurrency <= 0 {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        fatalError("Implement Homework 2")
    }
}
```

- [ ] **Step 9: Run the new test and the starter's zero test**

Run: `swift test --filter "StudentTaskProcessorTests/testNegativeMaximumConcurrencyIsRejected|TaskProcessorPublicTests/testZeroMaximumConcurrencyIsRejected"`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 10: Commit**

```bash
git add Tests/TaskProcessorTests Sources/TaskProcessor/TaskProcessor.swift
git commit -m "feat: validate maximum concurrency and add test helpers"
```

---

### Task 2: Reject duplicate IDs before any worker runs (~15 min)

**Files:**
- Create: `Sources/TaskProcessor/Scheduler.swift`
- Modify: `Sources/TaskProcessor/TaskProcessor.swift` (body of `process`)
- Test: `Tests/TaskProcessorTests/StudentTaskProcessorTests.swift`

**Interfaces:**
- Consumes: `WorkerLog`, `makeJobs`, `scriptedWorker`, `errorThrown` (Task 1).
- Produces: `func checkForDuplicateIDs(_ jobs: [Job]) throws` (internal).

- [ ] **Step 1: Add the failing test inside `StudentTaskProcessorTests`**

`[a, b, a, b]`: the first job whose ID appeared earlier is the second `a`, so the error must be `.duplicateID("a")`. The scripted worker logs every start; an empty log afterwards proves no worker ran. `errorThrown` catches the error so we can compare it.

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter StudentTaskProcessorTests/testFirstRepeatedIDIsReportedAndNoWorkerRuns`
Expected: crash with `Fatal error: Implement Homework 2`

- [ ] **Step 3: Create `Sources/TaskProcessor/Scheduler.swift`**

A `Set` holds unique values and answers `contains` quickly. Walking left to right and throwing at the first ID already in the set gives exactly "the first job whose ID has appeared earlier".

```swift
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
```

- [ ] **Step 4: Call it at the start of `process` in `TaskProcessor.swift`**

```swift
    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try checkForDuplicateIDs(jobs)
        fatalError("Implement Homework 2")
    }
```

- [ ] **Step 5: Run it to verify it passes**

Run: `swift test --filter StudentTaskProcessorTests/testFirstRepeatedIDIsReportedAndNoWorkerRuns`
Expected: `Executed 1 test, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/TaskProcessor Tests/TaskProcessorTests/StudentTaskProcessorTests.swift
git commit -m "feat: reject duplicate job ids before any worker runs"
```

---

### Task 3: Run jobs within the limit, map outcomes, keep input order (~40 min)

**Files:**
- Modify: `Sources/TaskProcessor/Scheduler.swift` (add `runJobs` and `runJob`)
- Modify: `Sources/TaskProcessor/TaskProcessor.swift` (body of `process`)
- Test: `Tests/TaskProcessorTests/StudentTaskProcessorTests.swift`

**Interfaces:**
- Consumes: `checkForDuplicateIDs` (Task 2); `ControlledWorker`, `WorkerLog`, `makeJobs`, `expectedResults`, `scriptedWorker` (Task 1).
- Produces: `func runJobs(_ jobs: [Job], maximumConcurrency: Int, maximumAttempts: Int, worker: @escaping @Sendable (Job, Int) async throws -> Int) async -> [JobResult]` and `func runJob(_ job: Job, maximumAttempts: Int, worker: @Sendable (Job, Int) async throws -> Int) async -> JobOutcome` (both internal).

- [ ] **Step 1: Add four failing tests inside `StudentTaskProcessorTests`**

How the paused-worker tests read: `worker.start(…)` begins processing in the background, `waitUntilStarted` tells the test which jobs are running, and `finish` / `releaseAll` decide when they end. So the test, not timing, decides the order. The other two tests use `scriptedWorker`, which finishes at once.

```swift
    func testNoMoreThanLimitRunAndFreedSlotStartsNextJob() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let worker = ControlledWorker(["a", "b", "c", "d"])
        let processing = worker.start(makeJobs(["a", "b", "c", "d"]), on: processor)

        // "a" and "b" run in parallel, so either may log first: compare which jobs started, not their order.
        await worker.waitUntilStarted("a", "b")
        let startedWhileFull = await worker.log.startedIDs
        XCTAssertEqual(Set(startedWhileFull), ["a", "b"])

        await worker.finish("a")
        await worker.waitUntilStarted("c")
        let startedAfterOneFinished = await worker.log.startedIDs
        XCTAssertEqual(Set(startedAfterOneFinished), ["a", "b", "c"])

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
```

- [ ] **Step 2: Run one to verify it fails**

Run: `swift test --filter StudentTaskProcessorTests/testEachWorkerResultMapsToItsOutcome`
Expected: crash with `Fatal error: Implement Homework 2`

- [ ] **Step 3: Add `runJobs` and `runJob` to `Sources/TaskProcessor/Scheduler.swift`**

How `runJobs` works, in plain words:

1. `outcomes` has one box per job, all empty (`nil`). A job's outcome goes into the box with the job's own index, so the output order is the input order whatever order jobs finish in.
2. `withTaskGroup(of: (Int, JobOutcome).self)` creates the group. Each child returns a pair: its job's index and its outcome. The group is the non-throwing kind because `runJob` catches every worker error. One job failing must not stop the others.
3. The `while true` loop repeats two things. First, *fill the free slots*: while fewer than `maximumConcurrency` jobs are running and jobs remain, start the next one (left to right). Second, *wait for any one job to finish* with `await group.next()`, store its outcome, and lower `runningCount`. `group.next()` returns `nil` only when no child is left, and then the loop ends.
4. Finally, build the results in input order. `outcomes[index] ?? .cancelled` covers jobs that never started. That only happens after Task 4's cancellation check, but it also keeps the code free of `!` force-unwraps.

`let index = nextIndex` and `let job = jobs[index]` copy the values *before* `addTask`. The child task runs later and must not read `nextIndex`, which keeps changing.

`runJob` calls the worker once, attempt number 1. It converts the result: a returned value → `.succeeded(value)`, `CancellationError` → `.cancelled`, any other error → `.failed`. The order of the `catch` blocks matters: the specific one comes first. The `maximumAttempts` parameter is unused until Task 5.

```swift
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
            // Fill every free slot, left to right.
            while runningCount < maximumConcurrency
                && nextIndex < jobs.count {
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
```

- [ ] **Step 4: Replace the body of `process` in `TaskProcessor.swift`**

`runJobs` expects a worker that takes `(Job, Int)`. The base worker only takes `Job`, so we pass a small closure `{ job, _ in try await worker(job) }`. It receives the attempt number, ignores it (`_`), and calls the real worker. With `maximumAttempts: 1` there is no retry.

```swift
    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try checkForDuplicateIDs(jobs)
        // The base worker has no attempt number, so wrap it and allow exactly one attempt.
        return await runJobs(
            jobs,
            maximumConcurrency: maximumConcurrency,
            maximumAttempts: 1
        ) { job, _ in
            try await worker(job)
        }
    }
```

- [ ] **Step 5: Run the whole suite. The starter tests pass now too**

Run: `swift test`
Expected: `Executed 11 tests, with 0 failures` (5 starter + 6 yours)

- [ ] **Step 6: Commit**

```bash
git add Sources/TaskProcessor Tests/TaskProcessorTests/StudentTaskProcessorTests.swift
git commit -m "feat: run jobs within the concurrency limit in input order"
```

---

### Task 4: Stop starting jobs when the caller cancels (~15 min)

**Files:**
- Modify: `Sources/TaskProcessor/Scheduler.swift` (the inner `while` condition in `runJobs`)
- Test: `Tests/TaskProcessorTests/StudentTaskProcessorTests.swift`

**Interfaces:**
- Consumes: `runJobs` (Task 3), `ControlledWorker`, `makeJobs`, `expectedResults`.
- Produces: no new names. `runJobs` starts no job once `Task.isCancelled` is true.

- [ ] **Step 1: Add the failing test inside `StudentTaskProcessorTests`**

Story of the test: one slot, three jobs. The test lets `done` finish, waits until `running` has started, then cancels `process` and releases every job. `running` is a cooperative worker (`ControlledWorker` calls `try Task.checkCancellation()`), so it throws `CancellationError` and ends `.cancelled`. `queued` must never start: its outcome is `.cancelled` and it is missing from the log. The test releases *all* jobs, not just `running`, so that before the fix a wrongly started `queued` finishes and the test fails with a clear message instead of hanging.

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter StudentTaskProcessorTests/testCallerCancellationKeepsFinishedCancelsRunningSkipsQueued`
Expected: 1 failure: `("["done", "running", "queued"]") is not equal to ("["done", "running"]")`. The scheduler still starts `queued` after cancelling.

- [ ] **Step 3: Add the cancellation check in `runJobs`**

`Task.isCancelled` is true once the caller has cancelled. Adding it to the "fill free slots" condition means no new job starts after that. Jobs that are already running get cancelled by the task group itself. Jobs that never started keep an empty box, which becomes `.cancelled`.

Replace:

```swift
            // Fill every free slot, left to right.
            while runningCount < maximumConcurrency
                && nextIndex < jobs.count {
```

with:

```swift
            // Fill every free slot, left to right, unless the caller has cancelled.
            while runningCount < maximumConcurrency
                && nextIndex < jobs.count
                && !Task.isCancelled {
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: `Executed 12 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/TaskProcessor/Scheduler.swift Tests/TaskProcessorTests/StudentTaskProcessorTests.swift
git commit -m "feat: stop starting jobs when the caller cancels"
```

---

### Task 5: Retry extension, bonus (~30 min)

**Files:**
- Create: `Sources/TaskProcessor/RetryPolicy.swift`
- Modify: `Sources/TaskProcessor/Scheduler.swift` (replace `runJob`)
- Create: `Tests/TaskProcessorTests/RetryPolicyTests.swift`

**Interfaces:**
- Consumes: `checkForDuplicateIDs`, `runJobs`, `runJob`, `TaskProcessor.maximumConcurrency`, `WorkerLog`, `makeJobs`, `expectedResults`, `retryWorker`.
- Produces: public `RetryPolicy`, `RetryPolicyError`, `TaskProcessor.process(_:retryPolicy:worker:)`.

- [ ] **Step 1: Write the failing tests in `Tests/TaskProcessorTests/RetryPolicyTests.swift`**

`retryWorker` logs each attempt number in `WorkerLog.attempts`, so a test can check exactly which attempts happened, for example `[1, 2]`. `successAttempt: ["flaky": 2]` means "fail attempt 1, succeed on attempt 2". `testRetriesDoNotUseExtraSlots` uses one slot: if a retry used an extra slot, `peakRunning` would be 2, or job `b` would start between `a`'s attempts. `retryPolicy: RetryPolicy(maximumAttempts: 3)` can throw, which the one `try` at the start of the line covers.

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter RetryPolicyTests`
Expected: build error `cannot find 'RetryPolicy' in scope`

- [ ] **Step 3: Create `Sources/TaskProcessor/RetryPolicy.swift`**

`public extension TaskProcessor` adds a second `process` method to the actor from another file. Swift tells the two `process` methods apart by the `retryPolicy:` label. This one passes the two-argument worker straight to `runJobs`, with the policy's attempt limit.

```swift
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
```

- [ ] **Step 4: Replace `runJob` in `Scheduler.swift` with the retry version**

The loop tries attempts 1, 2, … up to `maximumAttempts`, all inside the same child task, so a retry never takes another slot. On success it returns right away. On `CancellationError` it returns `.cancelled` right away, so that error is never retried. On an ordinary error it moves on to the next attempt, unless this was the last one, which gives `.failed`. Before attempt 2 and later it checks `Task.isCancelled`: once the caller has cancelled, no new worker call may start. The `return .failed` after the loop is never reached, but Swift needs every path to return a value.

```swift
/// Calls the worker for one job, retrying ordinary errors until `maximumAttempts` is reached.
func runJob(
    _ job: Job,
    maximumAttempts: Int,
    worker: @Sendable (Job, Int) async throws -> Int
) async -> JobOutcome {
    for attempt in 1...maximumAttempts {
        // No new worker call may start after the caller has cancelled.
        if attempt > 1 && Task.isCancelled {
            return .cancelled
        }

        do {
            let value = try await worker(job, attempt)
            return .succeeded(value)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if attempt == maximumAttempts {
                return .failed
            }
        }
    }
    return .failed
}
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/TaskProcessor Tests/TaskProcessorTests/RetryPolicyTests.swift
git commit -m "feat: add deterministic retry policy"
```

---

### Task 6: Evidence, verification, PR (~20 min)

**Files:**
- Modify: `PLAN.md`
- Modify: `AGENT_WORKLOG.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a merged `main` commit SHA to submit.

- [ ] **Step 1: Strict-concurrency check**

Run: `swift build --build-tests -Xswiftc -warnings-as-errors`
Expected: `Build complete!` (`--build-tests` also checks the test files)

- [ ] **Step 2: Fill `PLAN.md`**

Replace the two HTML-comment placeholders and tick the milestones. Rewrite in your own words if you prefer; it must stay accurate.

```markdown
## Approach

One function, `runJobs`, runs every job inside a non-throwing task group. It loops: start jobs left to right while fewer than `maximumConcurrency` are running, then wait for any one job to finish, store its outcome at that job's index, and repeat. Because each outcome is stored by index, results come back in input order no matter which job finishes first. `runJob` calls the worker and turns its value, ordinary error, or `CancellationError` into `.succeeded`, `.failed`, or `.cancelled`, so no error escapes a child task. When the caller cancels, `Task.isCancelled` stops new jobs from starting, the task group cancels running ones, and jobs that never started are reported as `.cancelled`. Duplicate IDs are rejected by a left-to-right scan before any job starts. The retry extension reuses `runJobs` with a higher attempt limit; the attempts for one job run one after another inside that job's slot.

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.

## Risks and checks

- Timing-dependent tests would be flaky: tests control order with `ControlledWorker` (built on `Signal`), never with sleeps.
- Concurrency limit: `WorkerLog` tracks the peak number of running workers; the scheduling test asserts it equals the limit and that job `c` starts only after a slot frees.
- Cancellation race: the cancellation test uses one slot, so which job is done, running and queued is fixed before cancelling.
- Retries inside one slot: a one-slot test asserts the start order `a, a, b, b` and a peak of 1.
- Cancelling between retry attempts ends the job as `.cancelled` without another worker call, following the base rule that no new worker starts after cancellation.
- Strict concurrency: `swift build --build-tests -Xswiftc -warnings-as-errors` passes.
```

- [ ] **Step 3: Fill `AGENT_WORKLOG.md`**

Replace the example row with these rows. The student writes the "My review and decision" cells and the final review section after reading each diff. The agent leaves them empty and says so.

```markdown
| 2026-10-15 | Claude Code (Claude Opus 5.5) | Explained the assignment; ran a throwaway Swift 6.4 POC (compile + cancellation behaviour); wrote the design spec | | `artifacts/docs/superpowers/specs/2026-10-15-task-processor-design.md` |
| 2026-10-15 | Claude Code (Claude Opus 5.5) | Wrote a beginner-level implementation plan with explanations; verified its code in a scratch copy | | `artifacts/docs/superpowers/plans/2026-10-15-task-processor.md` |
| 2026-10-15 | Claude Code (Claude Opus 5.5) | Implementation, test-first, following the plan | | `swift test`: 18 tests, 0 failures; commits on `feat/task-processor` |
```

- [ ] **Step 4: Final suite run**

Run: `swift test`
Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 5: Commit, push, open the PR**

```bash
git add PLAN.md AGENT_WORKLOG.md
git commit -m "docs: fill plan and agent worklog"
git push -u origin feat/task-processor
gh pr create --repo Daria-Korotych/apd-hw-2 --base main --title "feat: implement bounded task processor with retry" --body "Implements the HW2 contract with one scheduler shared by base and retry processing. Verified with swift test (18 tests) and swift build -Xswiftc -warnings-as-errors."
```

- [ ] **Step 6: After the review cells are filled and the PR is merged, get the SHA to submit**

```bash
git switch main && git pull
git rev-parse HEAD
```

Submit the repository URL `https://github.com/Daria-Korotych/apd-hw-2` and that 40-character SHA.
