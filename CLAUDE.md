# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build (Debug)
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm -configuration Debug build

# Build (Release)
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm -configuration Release build

# Run all tests
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm test

# Run a specific test class
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm test -only-testing:ProTermTests/ANSIParserTests

# Lint
swiftlint lint --config ProTerm/.swiftlint.yml ProTerm/Source/

# Format
swiftformat ProTerm/Source/ --config ProTerm/.swiftformat
```

SwiftFormat settings: 4-space indent, 120-char line width, Swift 6.0.
SwiftLint has `trailing_whitespace`, `line_length`, and `identifier_name` disabled.

## Architecture

ProTerm is a SwiftUI macOS terminal emulator using MVVM + Combine. Source lives in `ProTerm/Source/`.

### State management

All major state objects are `ObservableObject` classes injected as `@EnvironmentObject` from `ProTermApp`:

- **`TerminalManager`** — session list, active tab index, tab metadata
- **`TerminalSession`** — per-session I/O buffer, PTY lifecycle, command history
- **`ThemeManager`** — appearance profiles, persistence to `~/Library/Application Support/ProTerm/Profiles.json`
- **`KeyboardShortcutsManager`** — keybinding state
- **`SSHSessionManager`** — SSH session orchestration (singleton)

### Terminal I/O (local shell)

`PTyWrapper` (Obj-C via `SafeFileHandle.h/m`) creates a master/slave PTY pair using `openpty`, then `posix_spawn`s `/bin/bash` or `/bin/zsh` with the slave as stdio. Output is read non-blocking via `DispatchSourceRead` on the master fd and published to `TerminalSession.output`. Input is written directly to the master fd. Window size is set via `TIOCSWINSZ`.

`PTYProcess` is a higher-level Swift wrapper over `PTyWrapper`. `ProcessRunner` is for simple fire-and-forget commands that don't need a PTY.

### SSH sessions

`SSHSessionManager` uses `PTyWrapper` to spawn the system `ssh` binary. `SSHArgsBuilder` constructs the argument list. Password handling is via a helper script referenced by the `PROTERM_SSH_PASSWORD` env var. The SSH scrollback buffer is intentionally large (10 MB) to handle paginated CLI output (e.g., Cisco `show run`).

### ANSI parsing

`ANSIParser` is a character-by-character state machine that converts raw terminal output to `AttributedString`. It handles SGR color/style codes, OSC 8 hyperlinks, and cursor movement. **Screen-clearing sequences (CSI 2J) are intentionally ignored** — the app operates in log/scrollback mode, not TUI mode. This is a deliberate design decision, not a bug.

### UI structure

```
ContentView
├── ButtonBarView          (toolbar actions)
├── Tab bar                (drag-reorderable, bound to TerminalManager)
└── TerminalView           (one per session)
    ├── TerminalOutputView (renders AttributedString from ANSIParser)
    └── TerminalInputBar   (CustomTextField → writes to PTY master fd)
```

Modal overlays: `CommandPaletteView`, `QuickCommandsPanel`, `SearchBarView`, `ChatbotView`.

### Persistence

- Sessions: `SessionPersistence` saves session IDs/titles to `~/Library/Application Support/ProTerm/sessions.json`. On launch, it restores tab count but not shell state.
- Profiles: `ThemeManager` JSON-encodes `AppearanceProfile` structs. Optional iCloud sync via `NSUbiquitousKeyValueStore`.
- Crash log: `~/Library/Caches/ProTermCrash.log`

### Focus management

`AppDelegate` aggressively reclaims window focus after tab switches and app activation. `CommandInputFocusController` posts `.focusCommandInput` notifications; `TerminalInputBar` receives them to direct `@FocusState` to the text field. If input focus appears broken, look here first.

## Code conventions

- MVVM with SwiftUI; prefer `struct` over `class` for value types
- `async/await` for concurrency; `Combine` (`@Published`, `@StateObject`) for reactive state
- `let` over `var`; `is`/`has`/`should` prefixes for booleans
- Protocol extensions for shared behavior
- SF Symbols for icons; support dark mode and Dynamic Type
