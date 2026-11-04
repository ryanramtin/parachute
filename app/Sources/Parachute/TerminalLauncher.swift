import AppKit
import Foundation

/// Opens Terminal.app running a command by writing a throwaway .command file
/// (avoids Apple Events / Automation permission prompts).
enum TerminalLauncher {
    static func run(_ script: String, name: String) {
        let body = """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
        \(script)
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parachute-app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).command")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(
                [url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } catch {
            NSSound.beep()
        }
    }

    static func restore() { run("parachute restore", name: "restore") }

    static func setup() {
        run("""
        echo "Parachute is not set up yet. To set it up, run:"
        echo
        echo "    parachute install"
        echo
        printf "Press Enter to run it now (Ctrl-C to cancel)... "
        read
        parachute install
        """, name: "setup")
    }
}
