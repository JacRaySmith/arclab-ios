import Foundation

/// Wall-clock accounting for the analysis pipeline, so a change to it is measured rather than believed.
///
/// Every expensive stage adds its own seconds here: `decode`, `planes`, `coreml`, `background`,
/// `candidates`, `link`, `template`, `vision.trajectory`, `vision.pose`, `fit`. The same object is
/// passed down through a whole window (or a whole scan), so the printed line is the complete bill.
/// Nothing here changes behaviour; it only counts.
public final class StageTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var order: [String] = []

    public init() {}

    /// Seconds on a monotonic clock. `Date()` is wall time and can step; this cannot.
    @inline(__always) public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    public func add(_ stage: String, _ seconds: Double, count: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        if totals[stage] == nil { order.append(stage) }
        totals[stage, default: 0] += seconds
        counts[stage, default: 0] += count
    }

    public func add(_ stage: String, since t0: Double, count: Int = 1) {
        add(stage, Self.now() - t0, count: count)
    }

    public func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let t0 = Self.now()
        defer { add(stage, since: t0) }
        return try body()
    }

    public func measureAsync<T>(_ stage: String, _ body: () async throws -> T) async rethrows -> T {
        let t0 = Self.now()
        defer { add(stage, since: t0) }
        return try await body()
    }

    /// Fold another timer's stages into this one (a per-window timer into a per-session one).
    public func absorb(_ other: StageTimings) {
        for (stage, seconds) in other.orderedTotals { add(stage, seconds, count: other.count(stage)) }
    }

    public func count(_ stage: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[stage] ?? 0 }
    public func seconds(_ stage: String) -> Double { lock.lock(); defer { lock.unlock() }; return totals[stage] ?? 0 }

    /// Stages in the order they were first seen, with their totals.
    public var orderedTotals: [(stage: String, seconds: Double)] {
        lock.lock(); defer { lock.unlock() }
        return order.map { ($0, totals[$0] ?? 0) }
    }

    public var total: Double { lock.lock(); defer { lock.unlock() }; return totals.values.reduce(0, +) }

    /// One line, biggest stage first: `decode 1.82  coreml 0.91  candidates 0.44 …`.
    public func line(prefix: String = "stages:") -> String {
        let parts = orderedTotals.sorted { $0.seconds > $1.seconds }
            .filter { $0.seconds >= 0.005 }
            .map { String(format: "%@ %.2f", $0.stage, $0.seconds) }
        return parts.isEmpty ? "\(prefix) (nothing measured)" : "\(prefix) " + parts.joined(separator: "  ")
    }

    public var dictionary: [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return totals
    }
}

/// `StageTimings?` behaves like a timer that is simply not recording, so a call site never has to branch
/// on whether anyone asked for numbers.
public extension Optional where Wrapped == StageTimings {
    func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        guard let self else { return try body() }
        return try self.measure(stage, body)
    }
    func measureAsync<T>(_ stage: String, _ body: () async throws -> T) async rethrows -> T {
        guard let self else { return try await body() }
        return try await self.measureAsync(stage, body)
    }
}
