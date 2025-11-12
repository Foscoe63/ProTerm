# AGENTS.md

This file provides guidance to agents when working with code in this repository (Debug mode).

## Non‑Obvious Debugging Rules
- `TerminalSession.isProcessRunning` may toggle a short time after the underlying process exits (see lines 329‑332 & 581‑582). Guard UI updates with a debounce or check the process state before reacting.
- `ProTermApp` accesses `CrashReporter.shared` and `NotificationHelper.shared` in its initializer. If either crashes, the whole app fails to launch; place breakpoints early in `ProTermApp.init()` to verify they exist.
- No linting/formatting configuration is present. Use Xcode’s built‑in formatter; rely on the Swift compiler for style warnings.
- The custom `TEST_HOST` setting means unit tests require the app binary to be built first. When debugging a failing test, ensure `xcodebuild -scheme ProTerm` succeeds before running the test target.
- Xcode console logs are filtered by default. To see all `print` statements, enable “All Output” in the debug console.