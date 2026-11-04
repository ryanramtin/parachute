# Parachute (menu bar app)

Native macOS menu bar companion for the `parachute` CLI. It only reads the CLI's status file and shells out to the CLI.
Swift Package, no Xcode project. macOS 13+.

## Build

    ./build-app.sh              # -> build/Parachute.app (LSUIElement, dev.parachute.app, 0.1.0, ad-hoc signed)
    swift test                  # XCTest: decode tolerance, stale pid, time format, menu mapping, renderer
    swift run parachute-render-sheet   # -> build/frames.png (contact sheet, light+dark) and build/preview.gif

## How it finds the CLI

"Back up now" runs `~/.local/bin/parachute run` if executable, else `/usr/bin/env parachute run` with
`PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH`. Runs in a background `Process`; the menu item is disabled
while running. "Restore…" / "Set up…" write a temp `.command` file and open it in Terminal (no Automation prompt needed).
Log/config: the CLI's file names are not in the contract, so the app probes `parachute.log|run.log|...` in the state dir
and `config.toml|json|yaml|yml` in `${XDG_CONFIG_HOME:-~/.config}/parachute/`, falling back to opening the directory.

## Status contract (read-only)

`${XDG_STATE_HOME:-~/.local/state}/parachute/status.json`:
`version, state(idle|running|error), pid, lastRunStart, lastRunEnd, lastResult(ok|error|partial), reposScanned,
worktreesScanned, snapshots, pushedRefs, skipped, warnings[], nextRunEpoch`.
Polled every 1s while running / 5s idle, plus a directory DispatchSource for instant wakeups. Missing file = "Not set up";
malformed JSON = last good state kept; unknown keys ignored; wrong-typed keys fall back to defaults;
`running` with a dead pid (`kill(pid,0)`) is shown as idle with a "stopped unexpectedly" warning.

## Icon

Template `NSImage` drawn with CoreGraphics (no assets), rendered at the display's backing scale. Running: 12 frames @10fps
(inflate/deflate, +-8 deg sway, 1.6px drift then reset). Finishing OK plays a 0.8s landing. Error = dot badge,
partial = "!" badge (both with cut-out halo). Reduce Motion = static chute with a 1s opacity pulse. No timer when not animating.

## Known limitations

- Ad-hoc signed, not notarized: first launch needs right-click > Open (Gatekeeper). Launch at login (SMAppService)
  may require approval in System Settings > General > Login Items.
- Log/config file names are guesses (see above).
- Landing plays only when the app observes running -> idle/ok; a run shorter than the poll interval may be missed.
