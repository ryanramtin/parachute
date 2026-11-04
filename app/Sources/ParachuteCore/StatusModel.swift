import Foundation

public enum RunState: String, Equatable {
    case idle, running, error
}

public enum RunResult: String, Equatable {
    case ok, error, partial
}

/// Contents of `${XDG_STATE_HOME:-~/.local/state}/parachute/status.json`.
/// Decoding is deliberately tolerant: missing keys get defaults, wrongly-typed
/// keys are ignored, unknown keys are skipped. Only a non-object / malformed
/// document throws (callers then keep the last good state).
public struct StatusModel: Codable, Equatable {
    public var version: Int
    public var state: RunState
    public var pid: Int?
    public var lastRunStart: Int?
    public var lastRunEnd: Int?
    public var lastResult: RunResult?
    public var reposScanned: Int
    public var worktreesScanned: Int
    public var snapshots: Int
    public var pushedRefs: Int
    public var skipped: Int
    public var warnings: [String]
    public var nextRunEpoch: Int?
    /// Set by `effective(isAlive:)` when state==running but the pid is dead.
    public var isStale: Bool = false

    public init(version: Int = 1, state: RunState = .idle, pid: Int? = nil,
                lastRunStart: Int? = nil, lastRunEnd: Int? = nil, lastResult: RunResult? = nil,
                reposScanned: Int = 0, worktreesScanned: Int = 0, snapshots: Int = 0,
                pushedRefs: Int = 0, skipped: Int = 0, warnings: [String] = [],
                nextRunEpoch: Int? = nil) {
        self.version = version; self.state = state; self.pid = pid
        self.lastRunStart = lastRunStart; self.lastRunEnd = lastRunEnd; self.lastResult = lastResult
        self.reposScanned = reposScanned; self.worktreesScanned = worktreesScanned
        self.snapshots = snapshots; self.pushedRefs = pushedRefs; self.skipped = skipped
        self.warnings = warnings; self.nextRunEpoch = nextRunEpoch
    }

    enum CodingKeys: String, CodingKey {
        case version, state, pid, lastRunStart, lastRunEnd, lastResult
        case reposScanned, worktreesScanned, snapshots, pushedRefs, skipped, warnings, nextRunEpoch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientInt(.version) ?? 1
        state = (try? c.decodeIfPresent(String.self, forKey: .state)).flatMap { RunState(rawValue: $0) } ?? .idle
        pid = c.lenientInt(.pid)
        lastRunStart = c.lenientInt(.lastRunStart)
        lastRunEnd = c.lenientInt(.lastRunEnd)
        lastResult = (try? c.decodeIfPresent(String.self, forKey: .lastResult)).flatMap { RunResult(rawValue: $0) }
        reposScanned = max(0, c.lenientInt(.reposScanned) ?? 0)
        worktreesScanned = max(0, c.lenientInt(.worktreesScanned) ?? 0)
        snapshots = max(0, c.lenientInt(.snapshots) ?? 0)
        pushedRefs = max(0, c.lenientInt(.pushedRefs) ?? 0)
        skipped = max(0, c.lenientInt(.skipped) ?? 0)
        nextRunEpoch = c.lenientInt(.nextRunEpoch)
        warnings = c.lenientStrings(.warnings)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(state.rawValue, forKey: .state)
        try c.encode(pid, forKey: .pid)
        try c.encode(lastRunStart, forKey: .lastRunStart)
        try c.encode(lastRunEnd, forKey: .lastRunEnd)
        try c.encode(lastResult?.rawValue, forKey: .lastResult)
        try c.encode(reposScanned, forKey: .reposScanned)
        try c.encode(worktreesScanned, forKey: .worktreesScanned)
        try c.encode(snapshots, forKey: .snapshots)
        try c.encode(pushedRefs, forKey: .pushedRefs)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(nextRunEpoch, forKey: .nextRunEpoch)
    }

    public static func decode(_ data: Data) throws -> StatusModel {
        try JSONDecoder().decode(StatusModel.self, from: data)
    }

    /// Stale-pid logic: running + dead pid => idle (stale). pid==nil is trusted as running.
    public func effective(isAlive: (Int) -> Bool = StatusModel.pidIsAlive) -> StatusModel {
        guard state == .running, let pid = pid, !isAlive(pid) else { return self }
        var copy = self
        copy.state = .idle
        copy.isStale = true
        return copy
    }

    public static func pidIsAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

extension KeyedDecodingContainer {
    func lenientInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite, abs(d) < 9e15 { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key), let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
        return nil
    }

    func lenientStrings(_ key: Key) -> [String] {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s.isEmpty ? [] : [s] }
        guard var u = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [String] = []
        while !u.isAtEnd {
            if let s = try? u.decode(String.self) { out.append(s) } else { _ = try? u.decode(Skip.self) }
        }
        return out
    }
}
