import Foundation

/// Thread-safe ring buffer shared between the data source (background queue) and the chart (main thread).
/// Deliberately not observable: the chart pulls snapshots on its own frame clock instead of
/// invalidating SwiftUI 100 times a second.
final class SampleBuffer: @unchecked Sendable {
    struct Snapshot {
        var channels: [[Double]]
        /// Total samples received since the last reset; anchors the scrolling time grid.
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

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        count = 0
        total = 0
        unparsed = 0
        rate = 0
        rateWindowCount = 0
    }

    func snapshot(last n: Int) -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let k = min(n, count)
        let start = (head - k + capacity) % capacity
        let channels = storage.map { values -> [Double] in
            if start + k <= capacity { return Array(values[start..<start + k]) }
            return Array(values[start..<capacity]) + Array(values[0..<(start + k - capacity)])
        }
        let stale = now - lastArrival > 1.5
        return Snapshot(channels: channels, total: total, samplesPerSecond: stale ? 0 : rate, unparsedLines: unparsed)
    }
}
