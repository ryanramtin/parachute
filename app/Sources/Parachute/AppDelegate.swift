import AppKit
import ParachuteCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths = ParachutePaths()
    private lazy var watcher = StatusWatcher(url: paths.statusFile)
    private let runner = Runner()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var status: StatusModel?
    private var runnerBusy = false
    private var runnerError: String?
    private var menuOpen = false
    private var presentation: MenuPresentation!
    private var wasRunning = false

    // icon animation
    private var currentStyle: IconStyle?
    private var frameIndex = 0
    private var iconTimer: Timer?
    private var frameCache: [String: NSImage] = [:]

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityLabel("Parachute backup")
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPrefChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        watcher.onPoll = { [weak self] s in self?.statusChanged(s) }
        refresh(from: nil)
        watcher.start()
    }

    func applicationWillTerminate(_ notification: Notification) { watcher.stop() }

    // MARK: state

    private func statusChanged(_ s: StatusModel?) {
        status = s
        refresh(from: s)
    }

    @objc private func motionPrefChanged() { refresh(from: status) }

    private func refresh(from s: StatusModel?) {
        let p = MenuPresentation(status: s, runnerBusy: runnerBusy, runnerError: runnerError, reduceMotion: reduceMotion)
        let result = s?.effective().lastResult
        let land = MenuPresentation.shouldLand(previouslyRunning: wasRunning, current: p, result: result) && !reduceMotion
        wasRunning = p.isRunning
        let changed = presentation != p
        presentation = p
        applyIcon(land ? .landing : p.baseStyle)
        if changed && !menuOpen { rebuildMenu() }
    }

    // MARK: icon

    private func image(_ style: IconStyle, _ i: Int) -> NSImage {
        let key = "\(style)-\(i)"
        if let c = frameCache[key] { return c }
        let img = ParachuteIconRenderer.frame(index: i, count: style.frameCount, style: style)
        frameCache[key] = img
        return img
    }

    private func applyIcon(_ style: IconStyle) {
        // A landing in progress must not be cut short by a repeated idle poll.
        if currentStyle == .landing && iconTimer != nil && style != .landing && style != .running && style != .reducedMotion { return }
        if style == currentStyle { return }
        currentStyle = style
        frameIndex = 0
        iconTimer?.invalidate(); iconTimer = nil
        statusItem.button?.image = image(style, 0)
        statusItem.button?.alphaValue = 1
        guard style.isAnimated else { return }
        let t = Timer(timeInterval: 1 / style.framesPerSecond, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.frameIndex += 1
            if style == .landing && self.frameIndex >= style.frameCount {
                timer.invalidate(); self.iconTimer = nil
                self.currentStyle = nil           // let the real base style take over
                self.applyIcon(self.presentation.baseStyle)
                return
            }
            self.statusItem.button?.image = self.image(style, self.frameIndex % style.frameCount)
        }
        RunLoop.main.add(t, forMode: .common)   // keeps animating while the menu is open
        iconTimer = t
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // relative times may have aged since the last rebuild
        presentation = MenuPresentation(status: status, runnerBusy: runnerBusy, runnerError: runnerError, reduceMotion: reduceMotion)
        rebuildMenu()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; refresh(from: status) }

    private func info(_ title: String, bold: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        if bold { i.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)]) }
        return i
    }

    private func item(_ title: String, _ sel: Selector, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.isEnabled = enabled
        return i
    }

    private func rebuildMenu() {
        guard let p = presentation else { return }
        menu.removeAllItems()
        menu.addItem(info(p.header, bold: true))
        if p.notSetUp {
            menu.addItem(item("Set up…", #selector(setUp)))
        } else {
            p.details.forEach { menu.addItem(info($0)) }
        }
        if !p.warnings.isEmpty {
            menu.addItem(.separator())
            p.warnings.forEach { menu.addItem(info("⚠︎ " + $0.prefix(80))) }
            if p.hiddenWarningCount > 0 { menu.addItem(info("…and \(p.hiddenWarningCount) more")) }
            menu.addItem(item("Show log", #selector(openLog)))
        }
        menu.addItem(.separator())
        menu.addItem(item(p.isRunning ? "Backing up…" : "Back up now", #selector(backUpNow), enabled: !p.isRunning))
        menu.addItem(item("Restore…", #selector(restore)))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(item("Open config", #selector(openConfig)))
        menu.addItem(.separator())
        let login = item("Launch at login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let quit = item("Quit Parachute", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: actions

    @objc private func backUpNow() {
        runnerError = nil
        runnerBusy = true
        let started = runner.run { [weak self] err in
            guard let self = self else { return }
            self.runnerBusy = false
            self.runnerError = err
            self.watcher.poll()
        }
        if !started { runnerBusy = true }
        refresh(from: status)
    }

    @objc private func setUp() { TerminalLauncher.setup() }
    @objc private func restore() { TerminalLauncher.restore() }
    @objc private func openLog() { NSWorkspace.shared.open(paths.logFile()) }
    @objc private func openConfig() { NSWorkspace.shared.open(paths.configFile()) }

    @objc private func toggleLogin() {
        if let err = LoginItem.set(!LoginItem.isEnabled) {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at login"
            a.informativeText = err
            a.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
