# AGENTS.md

This file provides guidance to agents when working with code in this repository (Ask mode).

## Non‑Obvious Documentation Rules
- The primary SwiftUI source lives under `ProTerm/Source`; there is no separate web front‑end. Do not assume a typical web project structure.
- Provider example implementations in `ProTerm/Source/AIIntegration.swift` are the canonical reference; official documentation is outdated.
- UI runs inside a VSCode webview with limited APIs (no `localStorage`, restricted file system access). Treat it as a sandboxed environment.
- Two distinct localization systems exist: root‑level `*.lproj` files for the extension and `ProTerm/Source/UI/i18n` for the webview UI. Mixing them causes missing strings.
- `Package.swift` scripts must be executed from the project root; running them from sub‑directories will fail to locate dependencies.