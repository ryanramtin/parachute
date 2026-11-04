import Foundation

public enum StatusLoader {
    public enum Result: Equatable { case missing, ok(StatusModel), invalid }
    public static func load(_ url: URL) -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let m = try? StatusModel.decode(data) else { return .invalid }
        return .ok(m)
    }
}

/// Polls the status file (1s while running, 5s idle) plus a directory DispatchSource for fast wakeups.
/// Malformed content keeps the last good state. `onPoll` fires on the main queue after every poll.
public final class StatusWatcher {
    public private(set) var current: StatusModel?   // nil == not set up
    public var onPoll: ((StatusModel?) -> Void)?

    private let url: URL
    private var timer: DispatchSourceTimer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var interval: TimeInterval = 5

    public init(url: URL) { self.url = url }

    public func start() {
        poll()
    }

    public func stop() {
        timer?.cancel(); timer = nil
        dirSource?.cancel(); dirSource = nil
    }

    public func poll() {
        switch StatusLoader.load(url) {
        case .missing: current = nil
        case .ok(let m): current = m
        case .invalid: break
        }
        attachDirectoryIfNeeded()
        // Adaptive cadence; "running" is judged on the effective (pid-checked) state.
        let running = current?.effective().state == .running
        schedule(running ? 1 : 5)
        onPoll?(current)
    }

    private func schedule(_ secs: TimeInterval) {
        if timer != nil && interval == secs { return }
        interval = secs
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + secs, repeating: secs, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func attachDirectoryIfNeeded() {
        guard dirSource == nil else { return }
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in self?.poll() }
        s.setCancelHandler { close(fd) }
        s.resume()
        dirSource = s
    }
}
