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
