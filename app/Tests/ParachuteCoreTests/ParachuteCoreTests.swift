import XCTest
import AppKit
@testable import ParachuteCore

final class StatusModelTests: XCTestCase {
    func decode(_ s: String) throws -> StatusModel { try StatusModel.decode(Data(s.utf8)) }

    func testFullDecode() throws {
        let m = try decode(#"{"version":1,"state":"running","pid":42,"lastRunStart":100,"lastRunEnd":200,"lastResult":"partial","reposScanned":3,"worktreesScanned":4,"snapshots":5,"pushedRefs":6,"skipped":7,"warnings":["a","b"],"nextRunEpoch":999}"#)
        XCTAssertEqual(m.state, .running); XCTAssertEqual(m.pid, 42); XCTAssertEqual(m.lastResult, .partial)
        XCTAssertEqual(m.reposScanned, 3); XCTAssertEqual(m.skipped, 7); XCTAssertEqual(m.warnings, ["a", "b"])
        XCTAssertEqual(m.nextRunEpoch, 999)
    }
    func testMissingKeysGetDefaults() throws {
        let m = try decode("{}")
        XCTAssertEqual(m.state, .idle); XCTAssertNil(m.pid); XCTAssertNil(m.lastResult)
        XCTAssertEqual(m.snapshots, 0); XCTAssertEqual(m.warnings, [])
    }
    func testNullsAndBadTypes() throws {
        let m = try decode(#"{"state":7,"pid":"123","lastRunEnd":"x","lastResult":"weird","snapshots":"9","reposScanned":4.0,"warnings":[1,"ok",null,{"a":1}],"skipped":-3}"#)
        XCTAssertEqual(m.state, .idle); XCTAssertEqual(m.pid, 123); XCTAssertNil(m.lastRunEnd)
        XCTAssertNil(m.lastResult); XCTAssertEqual(m.snapshots, 9); XCTAssertEqual(m.reposScanned, 4)
        XCTAssertEqual(m.warnings, ["ok"]); XCTAssertEqual(m.skipped, 0)
    }
    func testWarningsAsSingleString() throws { XCTAssertEqual(try decode(#"{"warnings":"boom"}"#).warnings, ["boom"]) }
    func testUnknownKeysIgnored() throws {
        let m = try decode(#"{"state":"error","future":{"x":[1,2]},"snapshots":2}"#)
        XCTAssertEqual(m.state, .error); XCTAssertEqual(m.snapshots, 2)
    }
    func testMalformedThrows() {
        XCTAssertThrowsError(try decode("{not json"))
        XCTAssertThrowsError(try decode("[1,2]"))
        XCTAssertThrowsError(try decode(""))
    }
    func testStalePid() {
        let running = StatusModel(state: .running, pid: 4242)
        let dead = running.effective(isAlive: { _ in false })
        XCTAssertEqual(dead.state, .idle); XCTAssertTrue(dead.isStale)
        let alive = running.effective(isAlive: { _ in true })
        XCTAssertEqual(alive.state, .running); XCTAssertFalse(alive.isStale)
        XCTAssertEqual(StatusModel(state: .running, pid: nil).effective(isAlive: { _ in false }).state, .running)
        XCTAssertEqual(StatusModel(state: .error, pid: 1).effective(isAlive: { _ in false }).state, .error)
    }
    func testRealPidCheck() {
        XCTAssertTrue(StatusModel.pidIsAlive(Int(getpid())))
        XCTAssertFalse(StatusModel.pidIsAlive(0)); XCTAssertFalse(StatusModel.pidIsAlive(-5))
        XCTAssertFalse(StatusModel.pidIsAlive(Int(Int32.max)))
    }
    func testLoaderKeepsNothingOnMissing() {
        XCTAssertEqual(StatusLoader.load(URL(fileURLWithPath: "/nonexistent/x/status.json")), .missing)
    }
}

final class TimeFormatTests: XCTestCase {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    // 2026-11-03 15:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_793_718_000)
    func past(_ secs: Int) -> String { TimeFormat.relativePast(epoch: Int(now.timeIntervalSince1970) - secs, now: now, calendar: cal) }
    func testPast() {
        XCTAssertEqual(past(5), "just now"); XCTAssertEqual(past(-30), "just now")
        XCTAssertEqual(past(4 * 60 + 10), "4m ago"); XCTAssertEqual(past(59 * 60), "59m ago")
        XCTAssertEqual(past(2 * 3600), "2h ago")
        XCTAssertEqual(past(20 * 3600), "yesterday")
        XCTAssertEqual(past(30 * 3600), "yesterday")
        XCTAssertEqual(past(3 * 86400), "3d ago")
    }
    func testFuture() {
        func f(_ s: Int) -> String { TimeFormat.relativeFuture(epoch: Int(now.timeIntervalSince1970) + s, now: now, calendar: cal) }
        XCTAssertEqual(f(10), "due now"); XCTAssertEqual(f(12 * 60), "in 12m"); XCTAssertEqual(f(3 * 3600), "in 3h")
        XCTAssertEqual(f(12 * 3600), "tomorrow"); XCTAssertEqual(f(4 * 86400), "in 4d")
    }
}

final class PresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_718_000)
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    func p(_ s: StatusModel?, busy: Bool = false, err: String? = nil, reduce: Bool = false, alive: Bool = true) -> MenuPresentation {
        MenuPresentation(status: s, now: now, calendar: cal, runnerBusy: busy, runnerError: err, reduceMotion: reduce, isAlive: { _ in alive })
    }
    var nowI: Int { Int(now.timeIntervalSince1970) }

    func testNotSetUp() { let m = p(nil); XCTAssertEqual(m.header, "Not set up"); XCTAssertTrue(m.notSetUp); XCTAssertEqual(m.baseStyle, .notSetUp) }
    func testProtected() {
        let m = p(StatusModel(lastRunEnd: nowI - 240, lastResult: .ok, reposScanned: 2, snapshots: 5, pushedRefs: 3, nextRunEpoch: nowI + 900))
        XCTAssertEqual(m.header, "Protected · last backup 4m ago"); XCTAssertEqual(m.baseStyle, .idle)
        XCTAssertEqual(m.details.last, "Next run: in 15m")
    }
    func testRunning() {
        XCTAssertEqual(p(StatusModel(state: .running, pid: 1)).header, "Backing up…")
        XCTAssertEqual(p(StatusModel(state: .running, pid: 1)).baseStyle, .running)
        XCTAssertEqual(p(StatusModel(state: .running, pid: 1), reduce: true).baseStyle, .reducedMotion)
        XCTAssertEqual(p(StatusModel(), busy: true).header, "Backing up…")
    }
    func testErrorAndPartial() {
        XCTAssertEqual(p(StatusModel(state: .error)).header, "Needs attention")
        XCTAssertEqual(p(StatusModel(lastResult: .error)).baseStyle, .error)
        XCTAssertEqual(p(StatusModel(lastRunEnd: nowI - 60, lastResult: .partial)).baseStyle, .partial)
        XCTAssertEqual(p(StatusModel(lastResult: .ok), err: "boom").baseStyle, .error)
    }
    func testStaleRunningIsIdleWithWarning() {
        let m = p(StatusModel(state: .running, pid: 9, lastRunEnd: nowI - 600, lastResult: .ok), alive: false)
        XCTAssertFalse(m.isRunning); XCTAssertEqual(m.baseStyle, .idle)
        XCTAssertTrue(m.warnings.contains { $0.contains("unexpectedly") })
    }
    func testWarningCap() {
        let m = p(StatusModel(warnings: ["1", "2", "3", "4", "5"]))
        XCTAssertEqual(m.warnings, ["1", "2", "3"]); XCTAssertEqual(m.hiddenWarningCount, 2)
    }
    func testLanding() {
        let idle = p(StatusModel(lastRunEnd: nowI, lastResult: .ok))
        XCTAssertTrue(MenuPresentation.shouldLand(previouslyRunning: true, current: idle, result: .ok))
        XCTAssertFalse(MenuPresentation.shouldLand(previouslyRunning: false, current: idle, result: .ok))
        XCTAssertFalse(MenuPresentation.shouldLand(previouslyRunning: true, current: p(StatusModel(lastResult: .error)), result: .error))
    }
    func testPaths() {
        let a = ParachutePaths(env: [:], home: "/h"); XCTAssertEqual(a.statusFile.path, "/h/.local/state/parachute/status.json")
        let b = ParachutePaths(env: ["XDG_STATE_HOME": "/s"], home: "/h"); XCTAssertEqual(b.statusFile.path, "/s/parachute/status.json")
        XCTAssertEqual(b.logFile(exists: { _ in false }).path, "/s/parachute")
    }
    func testCLILocator() {
        let a = CLILocator.invocation(args: ["run"], home: "/h", basePath: "/usr/bin", isExecutable: { $0 == "/h/.local/bin/parachute" })
        XCTAssertEqual(a.executable, "/h/.local/bin/parachute"); XCTAssertEqual(a.arguments, ["run"])
        let b = CLILocator.invocation(args: ["run"], home: "/h", basePath: "/usr/bin", isExecutable: { _ in false })
        XCTAssertEqual(b.executable, "/usr/bin/env"); XCTAssertEqual(b.arguments, ["parachute", "run"])
        XCTAssertTrue(b.path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:/h/.local/bin"))
    }
}

final class RendererTests: XCTestCase {
    func testEveryFrameAndStyle() {
        for style in IconStyle.allCases {
            for i in 0..<style.frameCount {
                let img = ParachuteIconRenderer.frame(index: i, count: style.frameCount, style: style)
                XCTAssertEqual(img.size, ParachuteIconRenderer.size); XCTAssertTrue(img.isTemplate)
                for scale in [CGFloat(1), 2] {
                    let cg = ParachuteIconRenderer.cgImage(index: i, count: style.frameCount, style: style, scale: scale)
                    XCTAssertNotNil(cg, "\(style) \(i)")
                    XCTAssertEqual(cg?.width, Int(20 * scale)); XCTAssertEqual(cg?.height, Int(18 * scale))
                    XCTAssertGreaterThan(inkPixels(cg!), 20, "\(style) frame \(i) is empty")
                }
            }
        }
    }
    func testFramesDiffer() {
        let a = ParachuteIconRenderer.cgImage(index: 0, count: 12, style: .running, scale: 2)!
        let b = ParachuteIconRenderer.cgImage(index: 3, count: 12, style: .running, scale: 2)!
        XCTAssertNotEqual(data(a), data(b))
    }
    func testDeterministic() {
        let a = ParachuteIconRenderer.cgImage(index: 5, count: 12, style: .running, scale: 2)!
        let b = ParachuteIconRenderer.cgImage(index: 5, count: 12, style: .running, scale: 2)!
        XCTAssertEqual(data(a), data(b))
    }
    func testBadgeHasCutout() {
        let plain = inkPixels(ParachuteIconRenderer.cgImage(index: 0, count: 1, style: .idle, scale: 4)!)
        let err = inkPixels(ParachuteIconRenderer.cgImage(index: 0, count: 1, style: .error, scale: 4)!)
        XCTAssertGreaterThan(err, plain)
    }
    func testDrawsIntoRealContext() {
        let img = ParachuteIconRenderer.frame(index: 0, count: 12, style: .running)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 40, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        var ink = 0
        for y in 0..<36 { for x in 0..<40 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { ink += 1 } }
        XCTAssertGreaterThan(ink, 50)
    }
    func data(_ cg: CGImage) -> Data { cg.dataProvider!.data! as Data }
    func inkPixels(_ cg: CGImage) -> Int {
        let d = data(cg); var n = 0
        for i in stride(from: 3, to: d.count, by: 4) where d[i] > 20 { n += 1 }
        return n
    }
}
