import Foundation

/// Runs the CLI in a background Process; completion is delivered on the main queue.
public final class Runner {
    public private(set) var isRunning = false
    public init() {}

    /// Returns false if already running. Never blocks the caller.
    @discardableResult
    public func run(args: [String] = ["run"], completion: @escaping (_ error: String?) -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        let inv = CLILocator.invocation(args: args)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: inv.executable)
        p.arguments = inv.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = inv.path
        p.environment = env
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        // Drain stderr continuously (keep only a tail) so a chatty CLI can't deadlock on a full pipe.
        var tail = Data()
        let lock = NSLock()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            lock.lock(); tail.append(d); if tail.count > 4096 { tail = tail.suffix(4096) }; lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let t = tail; lock.unlock()
            let lastLine = String(decoding: t, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
            let msg: String? = proc.terminationStatus == 0 ? nil
                : "parachute run failed (exit \(proc.terminationStatus))" + (lastLine.map { ": \($0)" } ?? "")
            DispatchQueue.main.async { self?.isRunning = false; completion(msg) }
        }
        do { try p.run() } catch {
            isRunning = false
            DispatchQueue.main.async { completion("Could not launch parachute: \(error.localizedDescription)") }
        }
        return true
    }
}
