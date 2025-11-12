# AGENTS.md

This file provides guidance to agents when working with code in this repository (Architect mode).

## Non‑Obvious Architectural Rules
- **Stateless Providers** – All provider implementations in `ProTerm/Source/AIIntegration.swift` must be stateless; a hidden caching layer assumes no mutable state between calls.
- **IPC Channel Constraints** – Communication between the VSCode extension and the webview UI uses a strict set of messages defined in `ProTerm/Source/IPC/*.swift`. Adding new messages requires updating both the sender and receiver enums; otherwise the UI will silently drop them.
- **Database Migrations** – Migrations located in `ProTerm/Source/Migrations/` are forward‑only; there is no rollback support. Running a migration out of order will corrupt the local store.
- **Circular Types Dependency** – The `types` package (`ProTerm/Source/Types/`) is intentionally imported by many other packages, creating a circular dependency that the build system tolerates but can cause runtime linking issues if modified.
- **Extension‑Webview Separation** – UI code lives in `ProTerm/Source/UI/` and runs inside a sandboxed webview. It cannot access the file system directly; all file I/O must go through `ProTerm/Source/PluginManager.swift` which forwards requests to the host extension.
- **StateObject Injection** – Adding a new `@StateObject` manager requires updating the list in `ProTermApp.swift` **and** adding it to the `.environmentObject` chain for every view that consumes it; otherwise the view will receive a default empty instance.