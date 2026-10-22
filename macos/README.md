# Materialize.app

A native macOS app around the CLI: one icon to double-click, no terminal.

```bash
./macos/build-app.sh              # builds dist/Materialize.app
./macos/build-app.sh --install    # ...and copies it to /Applications
```

Apple silicon, macOS 12 or newer. Building needs the Xcode Command Line
Tools (`xcode-select --install`) and Rust; running needs neither.

## What it is

The app window is a `WKWebView` showing the same UI as `python3 ui/serve.py`,
but the app owns the whole stack:

```
Materialize.app/Contents/
  MacOS/Materialize        native Swift app (main.swift)
  Resources/bin/materialize  the release CLI binary
  Resources/ui/              serve.py + index.html
  Resources/AppIcon.icns     rendered by make-icon.py
```

On launch it picks the first free port in 8765-8795, starts the server as a
child process pointed at its own bundled binary, waits for the server to
answer, then loads the page. Quitting sends the server `SIGINT` so it removes
its scratch directory on the way out, the same as pressing Ctrl+C would.

Because everything it needs is inside the bundle, the app keeps working if
this checkout moves or is deleted, and it ignores any other `materialize` on
your `PATH`. Rebuild after changing `ui/` or the Rust source.

## Why it is built this way

- **No app sandbox and no entitlements.** The CLI shells out to the GPU and
  writes to a temp directory; sandboxing it would mean brokering both.
- **System Python.** `/usr/bin/python3` (Command Line Tools) runs the server,
  with Homebrew's as a fallback. A Finder launch has almost no `PATH`, so the
  candidates are absolute and each is executed once to check it really works.
- **Ad-hoc code signature.** Apple silicon refuses to run unsigned arm64
  binaries. `codesign --sign -` is enough for a locally built app; it is not
  notarized, so copying it to another Mac will trip Gatekeeper.
- **AppKit panels for files and downloads.** A web view cannot open a file
  picker or save a download by itself. `Open Texture…` and the drop zone both
  go through `NSOpenPanel`, and the .zip and Unity exports are handled by
  `WKDownloadDelegate`, which saves to `~/Downloads` and reveals the file in
  the Finder.

## Menu

| Item | Key |
|------|-----|
| Open Texture… | ⌘O |
| Reload | ⌘R |
| Actual Size / Zoom In / Zoom Out | ⌘0 / ⌘+ / ⌘- |
| Enter Full Screen | ⌃⌘F |
| Show Server Log | — |

## If it does not start

The app shows the reason and offers **Show Log**. The same log is at
`~/Library/Logs/Materialize.log`, and it holds the server's own output,
including which binary it is driving and every request the page makes.

Right-click anywhere in the window for **Inspect Element** — the Web
Inspector works exactly as it does in Safari.
