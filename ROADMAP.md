# ProTerm Roadmap: Triage and Plan

Status key: **Working** (done and wired), **Partial** (some UI or logic exists, gap noted), **Backend only** (model/manager code exists, no caller or UI), **Missing**.
Evidence comes from a source read on 2026-10-03; file names are under `ProTerm/Source/`.

## 1. Triage

| Area | Item | Status | Evidence / gap | Effort |
|---|---|---|---|---|
| Tabs | Drag-to-reorder | **Working** | `ContentView.swift` has `.onDrag` plus an `onMove` handler (~L120, L1024) | S: verify and polish only |
| Tabs | Per-tab scroll position | **Partial** | `TabMetadata.scrollPosition` and `terminalManager.scrollPositions` exist, and `TerminalView.swift:364-390` restores them. A comment at L390 says full offset tracking isn't done, so the saved value is likely stale or never written | M |
| Terminal | Split panes | **Backend only** | `AdvancedFeatures.createSplitPane` and others have zero callers; there is no pane layout view | L |
| Terminal | Replace-with-preview | **Missing** | Not found anywhere; needs a spec | M |
| Visual | Cursor customization | **Partial** | The `TerminalVisualSettings` model, the prefs picker and `CommandInputFocusController:178` all exist. Cursor style and blinking are applied to the input field only, and cursor color is unchecked | S |
| Visual | Output filtering | **Backend only** | `ProductivityTools.applyFilters` has no callers; filter model and persistence exist | M |
| Visual | Color-coded output | **Backend only** | `OutputFilter` has `.highlight` and a color; `TerminalSyntaxHighlighter` exists but isn't tied to filters; `BlinkingCursor`, `ScrollIndicators`, `BracketHighlighting` and `MinimapView` (VisualEnhancements) are unused | M |
| Visual | Collapsible sections | **Missing** | Needs command-boundary detection in `TerminalOutputAccumulator`. This is the design-sensitive item: output is a flat `AttributedString` | L |
| Sessions | Save/restore UI | **Partial** | `SessionPersistence` restores tab count and titles only, with no UI | M |
| Sessions | Templates UI | **Backend only** | `SessionTemplate` CRUD exists, but `useSessionTemplate` has no callers and nothing launches a session from a template | M |
| Sessions | Workspace management | **Missing** | Bookmarks exist in `ProductivityTools`; no workspace concept (a named group of tabs, cwd and templates) | L |
| SSH | Connection manager UI | **Working** | `PreferencesView.swift` ~L1687-2079 lists, edits and connects, and passwords are stored in the Keychain | S: polish only |
| SSH | Key management UI | **Partial** | Add, remove and set-default work, but `generateFingerprint` returns a random string and no `ssh-keygen` call exists, so there is no key generation or real fingerprint | S/M |
| Export | HTML | **Backend only** | `generateHTMLExport` exists with no caller or UI | S |
| Export | PDF | **Stub** | `generatePDFExport` returns the plain text bytes, which is not a PDF | M |
| Export | Share sheet | **Missing** | No `NSSharingService` or `ShareLink` anywhere | S |
| Advanced | Recording and playback | **Missing** | The `isRecording` in `PreferencesView:553` is the shortcut-capture state, not a terminal recorder | L |
| Advanced | Smarter completion | **Partial** | `getCompletions` is called from `TerminalView:2081`; it is a static list and alias expansion, with no filesystem, history or per-command completion | M |
| Shortcuts | Customizer UI | **Working** (corrected after M2 read) | Record/capture sheet, per-action overrides, reset, and conflict detection already exist | none |
| Shortcuts | Action binding | **Working** | `KeyboardShortcutsManager.Action` enum with overrides; adding new actions is the only gap | S |
| Palette | Movable window | **Partial** | `CommandPaletteView` is an in-window overlay at `ContentView:504`; `DraggablePanel.swift` already provides a drag modifier. A separate NSPanel would be the heavier option | S (drag) / M (window) |
| AI | Real SDK | **Mock** | `ChatbotView.getSiriResponse` is a keyword if-chain. LM Studio makes a real HTTP call (OpenAI-compatible). `AIManager` holds only prefs | M |
| Plugins | Protocol | **Missing** | `Plugin` and `PluginCommand` are data models, and install/enable just flip flags, so nothing is loaded or executed | L |
| Plugins | Management UI | **Missing** | No plugin list in prefs (confirm) | M |
| (bonus) | Cloud sync | **Stub** | `enableCloudSync` and `syncNow` have no callers, and the iCloud flag is off | defer |
| (bonus) | Docker/Git panels | **Backend only** | Data fetchers in `IntegrationFeatures`, with no UI | defer |

Two cross-cutting findings:

1. About 1,800 lines (`AdvancedFeatures`, `IntegrationFeatures`, `ProductivityTools`, `VisualEnhancements`) are injected as environment objects but mostly never called. The remaining work is mostly **wiring**, not new logic.
2. Per `CLAUDE.md`, the app runs in log/scrollback mode (CSI 2J is ignored on purpose). Split panes, collapsible sections and replace-with-preview must be designed around this and must not turn the app into a TUI.

## 2. Plan

Ordered by value over cost. Each milestone should build cleanly and be committed on its own.

### M0: Foundations (S)
- Add per-feature flags in `FeatureFlags.swift` so half-built features stay hidden.
- Run the tab reorder through a manual test and fix anything broken.
- Delete or hide the stub UI that does nothing, such as the cloud-sync toggles.

### M1: Quick wins from existing backend (S–M)
1. **Export:** wire `exportSession` into a File/toolbar menu with `NSSavePanel`, add a `ShareLink`/`NSSharingServicePicker` share sheet, and replace the fake PDF with a real one (render the `AttributedString` via `NSAttributedString` and `NSPrintOperation`/`createPDF`).
2. **Palette:** apply `draggablePanel()` to `CommandPaletteView`; later optionally move it to a floating `NSPanel`.
3. **Cursor customization:** apply cursor color to the input cell, and decide whether the output view needs a cursor.
4. **SSH keys:** use real `ssh-keygen -t ed25519` plus `ssh-keygen -lf` for fingerprints, via `ProcessRunner`.

### M2: Sessions and shortcuts (M)
1. **Per-tab scroll position:** track the real offset with a `GeometryReader`/preference key and write it to `scrollPositions`.
2. **Templates:** add a "New from template" menu entry that calls `useSessionTemplate`, creates the session with its cwd and env, and sends the initial commands.
3. **Session save/restore:** extend `SessionPersistence` to store cwd, shell and SSH connection ID, and offer a restore dialog.
4. **Shortcuts:** build an action registry with default bindings, conflict detection and a reset option, and show them in the customizer.

### M3: Output intelligence (M, design-sensitive)
1. **Output filters and color coding:** apply `OutputFilter` rules as a post-pass over parsed `AttributedString` runs, or during append in `TerminalOutputAccumulator`. Highlight only, and keep hide/dim optional because of the 10 MB SSH scrollback performance budget. Include a filter management UI.
2. **Smarter completion:** add path completion, history-weighted suggestions and an SSH-aware mode, building on `getCompletions`.
3. **AI:** replace the keyword chatbot with a provider protocol (`AIProvider`) that has implementations for the Anthropic API (key in the Keychain, streaming), the existing LM Studio client, and optionally OpenAI-compatible endpoints. Keep Siri out of the picker or label it honestly.

### M4: Structural features (L)
1. **Collapsible sections:** detect command boundaries (prompt regex plus an OSC 133 shell-integration hook for local shells), store ranges, and render folds in `TerminalOutputView`.
2. **Split panes:** build a pane tree view (`HSplit`/`VSplit`) hosting `TerminalView` instances, add per-pane focus (careful with `AppDelegate` focus reclaiming), and keep `CommandInputFocusController` working.
3. **Recording and playback:** record timestamped PTY output chunks to a `.protermrec` JSON-lines file, add a playback view with speed and seek controls, and export it to asciicast v2 for interoperability.
4. **Workspaces:** a named bundle of tabs, templates, cwd and SSH targets, saved and restorable, built on M2's persistence.

### M5: Plugins (L, decide scope first)
- Define the protocol first: either declarative (JSON commands that run shell scripts, sandboxed and easy) or executable (a Swift bundle, which is hard to sandbox and sign). **Recommendation:** declarative, command-only plugins in `~/Library/Application Support/ProTerm/Plugins/*/plugin.json`.
- Then add a management UI (list, enable, disable, install from folder) and have commands show up in the palette.
- Replace-with-preview is unspecified; get a spec before scheduling it.

### Open questions
- Replace-with-preview: what should it do? (Show a diff of a command's effect before running it?)
- Plugins: declarative or executable?
- Is sandbox/App Store distribution a goal? It affects plugins, `ssh-keygen` and file access.
- Is the Siri option meant to stay?

### Suggested order
M0 → M1 → M2 → M3 → M4 (collapsible sections, then split panes, then recording) → M5.

## Progress
- M0, M1: done (commit 1f2dd92).
- M2: scroll restore, session restore (title/color/cwd), templates (palette + Templates prefs tab) done. Shortcuts needed no work.
- M3: output filters (hide/extract/replace/highlight) + color coding (`OutputStyler`, Filters prefs tab), rewritten tab completion (`CompletionEngine`), AI provider layer (`AIProvider`: Claude, OpenAI-compatible, LM Studio, offline help; streaming; keys in Keychain). Unit tests: `xcodebuild ... test -only-testing:ProTermTests`.
- M4: collapsible command sections (`CommandSections`, opt-in in Preferences > Filters), asciicast recording + playback (`SessionRecorder`, `PlaybackSheet`), workspaces (Preferences > Workspaces), split panes (`PaneLayout`, `PaneViews`; Cmd+D / Shift+Cmd+D). A real-app UI test covers split + focus (`ProTermUITests/SplitPaneUITests`; UI tests launch with `-ProTermUITesting` so they don't touch saved tabs).
- M5: declarative plugins (`PluginManager`, Preferences > Plugins): plugin.json folders add palette commands; manifest hash approval, shell-quoted inputs. Removed mock plugin model and dead export stubs. Replace-with-preview still unspecified, not built.
- Pane layouts (shape, divider ratios, per-pane folders, active pane) now persist across relaunch.
