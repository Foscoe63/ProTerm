# AGENTS.md

This file provides guidance to agents when working with code in this repository (Code mode).

## Non‑Obvious Coding Rules
- Use `safeWriteJson()` from `ProTerm/Source/` for any file‑write operation; raw `JSONEncoder` writes have caused corruption in the past.
- All `@StateObject` managers must be added to both the declaration list in `ProTermApp.swift` **and** the `.environmentObject` chain; forgetting either breaks dependency injection.
- When adding new Objective‑C files, remember to list their headers in `ProTerm/Source/ProTerm-Bridging-Header.h`; otherwise the Swift compiler cannot see them.
- The `TerminalSession.isProcessRunning` flag may toggle after a short delay when the underlying process exits; guard UI updates with a debounce if you rely on this flag.
- No linting configuration is present; adhere to Swift’s default style and Xcode formatter. Do not assume `.swiftlint.yml` exists.