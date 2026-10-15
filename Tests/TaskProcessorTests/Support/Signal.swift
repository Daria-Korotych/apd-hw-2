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
