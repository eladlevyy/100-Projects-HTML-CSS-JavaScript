import Foundation

public enum InteractionKind: String, Sendable, Equatable, CaseIterable {
    case navigation
    case typing
    case scrolling
    case streaming
}

public struct PerformanceSample: Sendable, Equatable {
    public var interaction: InteractionKind
    public var milliseconds: Double

    public init(interaction: InteractionKind, milliseconds: Double) {
        self.interaction = interaction
        self.milliseconds = milliseconds
    }
}

public struct PerformanceReport: Sendable, Equatable {
    public var samples: [PerformanceSample]

    public init(samples: [PerformanceSample]) {
        self.samples = samples
    }

    public func averageMilliseconds(for interaction: InteractionKind) -> Double? {
        let values = samples.filter { $0.interaction == interaction }.map(\.milliseconds)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public func maxMilliseconds(for interaction: InteractionKind) -> Double? {
        samples.filter { $0.interaction == interaction }.map(\.milliseconds).max()
    }
}

public final class PerformanceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [PerformanceSample] = []

    public init() {}

    public func record(_ interaction: InteractionKind, milliseconds: Double) {
        lock.lock()
        samples.append(PerformanceSample(interaction: interaction, milliseconds: milliseconds))
        lock.unlock()
    }

    public func measure(_ interaction: InteractionKind, _ body: () -> Void) {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        record(interaction, milliseconds: milliseconds)
    }

    public func report() -> PerformanceReport {
        lock.lock()
        let copy = samples
        lock.unlock()
        return PerformanceReport(samples: copy)
    }

    public func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

public enum HistorySeeder {
    public static func messages(chatID: UUID, count: Int, now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [Message] {
        (0..<count).map { index in
            Message(
                id: UUID(),
                chatID: chatID,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "History row \(index). token\(index % 50) lives in this local transcript.",
                status: .complete,
                createdAt: now.addingTimeInterval(TimeInterval(index)),
                ordinal: index
            )
        }
    }
}
