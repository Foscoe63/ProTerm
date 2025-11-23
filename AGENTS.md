# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Build / Run Commands (non‑standard)
- Full build: `xcodebuild -scheme ProTerm -configuration Debug -derivedDataPath ./build`
- Run app: `open ./build/Debug/ProTerm.app`
- Unit tests (all): `xcodebuild test -scheme ProTermTests -destination 'platform=macOS,arch=x86_64'`
- Single test: `xcodebuild test -scheme ProTermTests -only-testing:ProTermTests/TestClass/testMethod`
> Test target uses a custom `TEST_HOST` pointing to the built app binary; build the app first.

## Architecture Gotchas
- Entry point is `ProTermApp` (`ProTerm/Source/ProTermApp.swift`). It creates many `@StateObject` managers; adding a new manager requires updating both the list and the `.environmentObject` chain.
- `CrashReporter.shared` and `NotificationHelper.shared` are accessed in `ProTermApp.init()`; they must exist before any UI appears.
- Default Settings scene was removed (see lines 44‑46 of `ProTermApp.swift`); re‑adding a Settings view will break the split‑view layout.

## Non‑Obvious Code Patterns
- `TerminalSession.swift` resets `isProcessRunning` if the underlying process disappears (lines 329‑332, 581‑582); the flag may flip after a short delay.
- No linting/formatting configs (`.swiftlint.yml`, `.swiftformat`) are present; rely on Swift’s default style and Xcode formatter.
- Bridging header `ProTerm/Source/ProTerm-Bridging-Header.h` is required for any new Objective‑C files; they must be added to this header.

## Help
- When a user requests code examples, setup or configuration steps, or library/API documentation, use the context7 tool. 

## Testing Details
- No `*Tests.swift` files exist; the test target is present but empty. Add tests under `ProTermTests/` and ensure they are linked.
- The test host must be built before running tests due to the custom `TEST_HOST` setting in the Xcode project.