import Foundation

public enum IconStyle: Equatable, CaseIterable {
    case idle, running, landing, error, partial, reducedMotion, notSetUp

    public var frameCount: Int {
        switch self {
        case .running: return 12
        case .landing: return 8
        case .reducedMotion: return 10
        default: return 1
        }
    }
    public var isAnimated: Bool { frameCount > 1 }
    public var framesPerSecond: Double { 10 }
}

/// Pure mapping from status (+ local runner state) to everything the menu shows.
public struct MenuPresentation: Equatable {
    public var header: String
    public var details: [String]
    public var warnings: [String]       // max 3
    public var hiddenWarningCount: Int
    public var baseStyle: IconStyle     // static style (never .landing)
    public var isRunning: Bool
    public var notSetUp: Bool

    public static let maxWarnings = 3

    public init(status: StatusModel?, now: Date = Date(), calendar: Calendar = .current,
                runnerBusy: Bool = false, runnerError: String? = nil, reduceMotion: Bool = false,
                isAlive: (Int) -> Bool = StatusModel.pidIsAlive) {
        guard let raw = status else {
            header = runnerBusy ? "Backing up…" : "Not set up"
            details = []; warnings = runnerError.map { [$0] } ?? []; hiddenWarningCount = 0
            isRunning = runnerBusy; notSetUp = true
            baseStyle = runnerBusy ? (reduceMotion ? .reducedMotion : .running) : .notSetUp
            return
        }
        let s = raw.effective(isAlive: isAlive)
        notSetUp = false
        isRunning = s.state == .running || runnerBusy

        var allWarnings = s.warnings
        if let e = runnerError { allWarnings.insert(e, at: 0) }
        if s.isStale { allWarnings.append("Last run stopped unexpectedly") }
        warnings = Array(allWarnings.prefix(Self.maxWarnings))
        hiddenWarningCount = max(0, allWarnings.count - Self.maxWarnings)

        let failed = s.state == .error || s.lastResult == .error || runnerError != nil
        let last = s.lastRunEnd.map { TimeFormat.relativePast(epoch: $0, now: now, calendar: calendar) }

        if isRunning {
            header = "Backing up…"
            baseStyle = reduceMotion ? .reducedMotion : .running
        } else if failed {
            header = "Needs attention"
            baseStyle = .error
        } else if s.lastResult == .partial {
            header = "Protected with warnings" + (last.map { " · last backup \($0)" } ?? "")
            baseStyle = .partial
        } else if let last = last {
            header = "Protected · last backup \(last)"
            baseStyle = .idle
        } else {
            header = "Waiting for first backup"
            baseStyle = .idle
        }

        var d = ["Repos scanned: \(s.reposScanned)" + (s.worktreesScanned > 0 ? " (+\(s.worktreesScanned) worktrees)" : "")
                 + (s.skipped > 0 ? ", \(s.skipped) skipped" : ""),
                 "Snapshots: \(s.snapshots)",
                 "Pushed refs: \(s.pushedRefs)"]
        if let n = s.nextRunEpoch {
            d.append("Next run: " + TimeFormat.relativeFuture(epoch: n, now: now, calendar: calendar))
        }
        details = d
    }

    /// Should finishing a run (running -> not running) play the landing animation?
    public static func shouldLand(previouslyRunning: Bool, current: MenuPresentation, result: RunResult?) -> Bool {
        previouslyRunning && !current.isRunning && !current.notSetUp && current.baseStyle == .idle && result != .error
    }
}
