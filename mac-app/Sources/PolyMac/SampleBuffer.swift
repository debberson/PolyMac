import Foundation

/// Thread-safe ring buffer shared between the data source (background queue) and the UI.
/// Deliberately not observable: the chart pulls snapshots on its own frame clock instead of
/// invalidating SwiftUI 100 times a second.
///
/// Samples are addressed by an absolute index that only ever grows (even across reconnects), so
/// question markers and calibration windows stay pinned to the right data.
final class SampleBuffer: @unchecked Sendable {
    struct Snapshot {
        var channels: [[Double]]
        /// Absolute index one past the newest sample.
        var total: Int
        var samplesPerSecond: Double
        var unparsedLines: Int
    }

    private let lock = NSLock()
    private let capacity: Int
    private var storage: [[Double]]
    private var head = 0
    private var count = 0
    private var total = 0
    private var unparsed = 0

    private var rateWindowStart: TimeInterval = 0
    private var rateWindowCount = 0
    private var rate: Double = 0
    private var lastArrival: TimeInterval = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = Array(repeating: Array(repeating: 0, count: capacity), count: Channel.allCases.count)
    }

    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func append(_ reading: Reading) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        for channel in Channel.allCases {
            storage[channel.rawValue][head] = reading.value(for: channel)
        }
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
        total += 1

        if rateWindowCount == 0 { rateWindowStart = now }
        rateWindowCount += 1
        let elapsed = now - rateWindowStart
        if elapsed >= 1 {
            rate = Double(rateWindowCount - 1) / elapsed
            rateWindowCount = 0
        }
        lastArrival = now
    }

    func noteUnparsedLine() {
        lock.lock()
        unparsed += 1
        lock.unlock()
    }

    /// Drops retained samples (e.g. on reconnect). The absolute index keeps counting.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
        unparsed = 0
        rate = 0
        rateWindowCount = 0
    }

    func snapshot(last n: Int) -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let stale = now - lastArrival > 1.5
        return Snapshot(
            channels: unlockedSamples(from: total - n, to: total),
            total: total,
            samplesPerSecond: stale ? 0 : rate,
            unparsedLines: unparsed
        )
    }

    /// Samples with absolute index in `start..<end`, clipped to what is still retained.
    func samples(from start: Int, to end: Int) -> [[Double]] {
        lock.lock()
        defer { lock.unlock() }
        return unlockedSamples(from: start, to: end)
    }

    /// Like `samples(from:to:)`, but also returns the absolute index of the first sample returned.
    func range(from start: Int, to end: Int) -> (first: Int, channels: [[Double]]) {
        lock.lock()
        defer { lock.unlock() }
        return (max(start, total - count), unlockedSamples(from: start, to: end))
    }

    private func unlockedSamples(from start: Int, to end: Int) -> [[Double]] {
        let first = max(start, total - count)
        let last = min(end, total)
        let k = max(last - first, 0)
        guard k > 0 else { return Array(repeating: [], count: storage.count) }
        let position = ((head - (total - first)) % capacity + capacity) % capacity
        return storage.map { values -> [Double] in
            if position + k <= capacity { return Array(values[position..<position + k]) }
            return Array(values[position..<capacity]) + Array(values[0..<(position + k - capacity)])
        }
    }
}
