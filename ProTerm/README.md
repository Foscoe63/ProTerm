# ProTerm – macOS Terminal‑style Application (Extended Feature Set)

## Overview
ProTerm is a SwiftUI‑based macOS app that mimics the look and feel of Apple’s Terminal.app while adding a modern, extensible UI:
- Configurable button bar
- Tabbed sessions (multiple terminals)
- Professional preferences panel with theme, font, and shortcut settings
- Search within terminal output
- Drag‑and‑drop file opening (read‑only view)
- Split‑pane placeholder for future side‑by‑side sessions
- SSH session support (via built‑in `ssh` process)
- Command history, notifications on command completion, and crash reporting
- Integration point for macOS 26 built‑in AI (Apple Intelligence) via `AIIntegration`
- Export/Print utilities, plugin architecture, and more.

All source files live under `/Users/ewg/ProTerm`.

## Project Structure
```
ProTerm/
├─ Source/                     # Swift source files
│   ├─ ProTermApp.swift
│   ├─ ContentView.swift
│   ├─ TerminalManager.swift
│   ├─ ThemeManager.swift
│   ├─ FontPickerView.swift
│   ├─ ButtonBarView.swift
│   ├─ TerminalView.swift
│   ├─ SearchBarView.swift
│   ├─ StatusBarView.swift
│   ├─ PreferencesView.swift
│   ├─ SSHSessionManager.swift
│   ├─ SessionPersistence.swift
│   ├─ ExportPrintManager.swift
│   ├─ NotificationHelper.swift
│   ├─ PluginManager.swift
│   ├─ CrashReporter.swift
│   └─ AIIntegration.swift
├─ README.md                   # This file
└─ (Xcode project will be generated in the same folder)
```

## Building & Running
1. **Open Xcode** → *File > New > Project* → **App** (macOS) → **SwiftUI** lifecycle.
2. Save the project inside `/Users/ewg/ProTerm` (replace any existing folder when prompted).
3. When the project opens, **add all `.swift` files** from the `Source/` folder (drag‑and‑drop or *Add Files to “ProTerm”*).
4. Ensure the target’s **Signing & Capabilities** are set (automatic signing works for a personal team).
5. Build (`⌘R`). The app launches with a single terminal tab.

## Feature Highlights & How to Use Them
| Feature | How to access / test |
|---------|----------------------|
| **Button bar** – New Tab, Close Tab, Preferences | Top‑most toolbar; the gear icon opens the Settings pane. |
| **Tab bar** | Each tab is labeled *Session 1*, *Session 2* …; click to switch. |
| **Search** | Type in the search field that appears when you start typing; matching lines are highlighted. |
| **SSH session** | In the button bar add a custom “New SSH” action (future UI) – for now you can call `SSHSessionManager.shared.startSSH(to: "host")` from code. |
| **Preferences** | Settings → Appearance (dark/light), Font selector, Shortcut placeholder. |
| **Drag‑and‑drop** | Drop any text file onto the window – it opens in a new read‑only tab. |
| **Export / Print** | Right‑click the terminal view (future context menu) – calls `ExportPrintManager.shared`. |
| **Notifications** | When a session is closed or a long‑running command finishes you’ll see a macOS notification. |
| **AI Assistant** | Use the `AIPromptView` (found in `AIIntegration.swift`) to send a prompt and receive a placeholder answer. Replace the stub with Apple’s real AI SDK when it ships. |
| **Plugins** | Place a compiled `.bundle` inside `ProTerm.app/Contents/PlugIns`; the app will enumerate them at launch. |
| **Crash reporting** | Uncaught exceptions are logged to `~/Library/Caches/ProTermCrash.log`. |

## Extending the App
- **Split‑pane UI** – replace `ContentView`’s single `TabView` with a custom split view that hosts two `TerminalView`s side‑by‑side.
- **Full AI integration** – swap the mock implementation in `AIIntegration.swift` with Apple’s official `AIAssistant` API (once documented). 
- **Keyboard shortcut customizer** – flesh out `ShortcutSettings` to let users bind actions (new tab, close tab, etc.) using the new `KeyboardShortcut` API.
- **Plugin ecosystem** – define a protocol that plugins must conform to (e.g., `ProTermPlugin`) and load them dynamically via `Bundle.load()`. 

## Persistence & State Saving
- Session IDs are saved by `SessionPersistence` to `~/Library/Application Support/ProTerm/sessions.json`. On launch the app restores the same number of tabs (content is re‑initialized). Extend this to also store scroll position, command history, and theme preferences.

## Known Limitations (as of this scaffold)
- The terminal view only displays static text; real PTY handling is not yet implemented.
- Search highlighting is case‑insensitive and line‑based – more advanced regex search can be added later.
- The AI integration is a mock; replace with the official macOS 26 framework when available.
- Shortcut customization UI is a placeholder.

## Next Steps for You
1. Implement PTY handling (e.g., using `openpty` or a third‑party Swift wrapper). 
2. Replace the mock AI code with Apple’s real AI SDK once released. 
3. Flesh out the plugin protocol and expose a UI for loading/unloading plugins at runtime.
4. Add split‑pane support if you need side‑by‑side terminals.
5. Polish the preferences UI (add color pickers, more font options, etc.).

---
*All files are ready under `/Users/ewg/ProTerm`. Follow the build steps above to get a running prototype, then iterate on the enhancements listed.*
