import Foundation

public struct ParachutePaths {
    public let home: String
    public let env: [String: String]

    public init(env: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory()) {
        self.env = env; self.home = home
    }

    private func xdg(_ key: String, _ fallback: String) -> String {
        if let v = env[key], v.hasPrefix("/") { return v }
        return home + "/" + fallback
    }

    public var stateDir: URL { URL(fileURLWithPath: xdg("XDG_STATE_HOME", ".local/state") + "/parachute") }
    public var configDir: URL { URL(fileURLWithPath: xdg("XDG_CONFIG_HOME", ".config") + "/parachute") }
    public var statusFile: URL { stateDir.appendingPathComponent("status.json") }

    /// The CLI logs to ~/Library/Logs/parachute.log on macOS and <state dir>/parachute.log elsewhere;
    /// fall back to the state directory when no log exists yet.
    public func logFile(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let candidates = [URL(fileURLWithPath: home + "/Library/Logs/parachute.log"),
                          stateDir.appendingPathComponent("parachute.log")]
        return candidates.first { exists($0.path) } ?? stateDir
    }
    /// The CLI reads a shell-sourceable ~/.config/parachute/config (no extension).
    public func configFile(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let u = configDir.appendingPathComponent("config")
        return exists(u.path) ? u : configDir
    }
}

public struct CLIInvocation: Equatable {
    public var executable: String
    public var arguments: [String]
    public var path: String
}

public enum CLILocator {
    /// Prefers ~/.local/bin/parachute, else `/usr/bin/env parachute` with an extended PATH.
    public static func invocation(args: [String], home: String = NSHomeDirectory(),
                                  basePath: String? = ProcessInfo.processInfo.environment["PATH"],
                                  isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> CLIInvocation {
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        let path = [extra, basePath ?? "/usr/bin:/bin"].joined(separator: ":")
        let local = home + "/.local/bin/parachute"
        if isExecutable(local) { return CLIInvocation(executable: local, arguments: args, path: path) }
        return CLIInvocation(executable: "/usr/bin/env", arguments: ["parachute"] + args, path: path)
    }
}
