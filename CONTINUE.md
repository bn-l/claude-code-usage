# ClaudeCodeUsage — Implementation Progress

## What was built

A macOS menu bar app that visualises Claude Code usage as a pie chart icon. The pie fills up as usage increases, transitioning from red (underutilised) to green (well-utilised). Clicking the icon opens a popover with live metrics, computed forecasts, and historical stats persisted in SQLite.

## Files created (18 total)

### Scaffold
- `Package.swift` — swift-tools-version 6.2, macOS 15, GRDB 7.9.0
- `project.yml` — xcodegen spec (application target, LSUIElement, CODE_SIGN_IDENTITY: "-", SWIFT_STRICT_CONCURRENCY: complete)
- `Justfile` — recipes: gen, app, app-release, run, clean
- `Info.plist` — LSUIElement=true, bundle id com.bml.claude-code-usage
- `ClaudeCodeUsage.entitlements` — com.apple.security.network.client

### Models
- `Sources/ClaudeCodeUsage/Models/APIResponse.swift` — `UsageWindow`, `UsageLimits` (Codable)
- `Sources/ClaudeCodeUsage/Models/UsageMetrics.swift` — computed metrics struct + `ColorTier` enum (5-tier color scheme with SwiftUI Color and CGColor)
- `Sources/ClaudeCodeUsage/Models/SessionSnapshot.swift` — session-start snapshot for budget calculations

### Services
- `Sources/ClaudeCodeUsage/Services/CredentialProvider.swift` — reads OAuth token from macOS Keychain via `SecItemCopyMatching`
- `Sources/ClaudeCodeUsage/Services/UsageAPIClient.swift` — URLSession GET to `https://api.anthropic.com/api/oauth/usage`
- `Sources/ClaudeCodeUsage/Services/UsageCalculator.swift` — pure functions implementing all maths from notes.md (sessionForecastPct, sessionBudgetUsedPct, combinedPct)
- `Sources/ClaudeCodeUsage/Services/UsageMonitor.swift` — @Observable @MainActor, 5-min polling, session-reset detection, AppConfig
- `Sources/ClaudeCodeUsage/Services/HistoryStore.swift` — GRDB SQLite (usage_snapshots + session_starts tables, history queries, 90-day auto-prune)

### Views
- `Sources/ClaudeCodeUsage/App.swift` — @main, MenuBarExtra(.window)
- `Sources/ClaudeCodeUsage/Views/PieChartIcon.swift` — 18×18pt NSImage pie chart via Core Graphics, transparent background, gray outline, color-coded fill
- `Sources/ClaudeCodeUsage/Views/PopoverView.swift` — main popover layout (~320pt wide), error/loading states, "Updated X ago" + Quit
- `Sources/ClaudeCodeUsage/Views/MetricsView.swift` — horizontal gauge bars (combined, session forecast, budget used, session, weekly)
- `Sources/ClaudeCodeUsage/Views/HistoryView.swift` — SQLite-backed stats (today's sessions, 7-day trend mini bar chart, budget hit rate, peak hours, avg sessions/day)

## Issues encountered and resolutions

### 1. `Bundle.module` access conflict
**Problem:** `Bundle+Resources.swift` referenced `Bundle.module` in the `#else` (SPM) branch. GRDB also generates its own `Bundle.module` (internal to GRDB). Since our target has no resources, SPM doesn't generate a `Bundle.module` for us, and the GRDB one is inaccessible — build error: `'module' is inaccessible due to 'internal' protection level`.

**Resolution:** Deleted `Bundle+Resources.swift` entirely. The app has no bundle resources — the pie chart icon is generated programmatically via Core Graphics.

### 2. Credentials file doesn't exist on macOS
**Problem:** The plan specified reading `~/.claude/.credentials.json`. On macOS, Claude Code stores OAuth credentials in the **macOS Keychain** (service name: `"Claude Code-credentials"`), not in a file. The `.credentials.json` path is only used on Linux/Windows.

**Resolution:** Rewrote `CredentialProvider` to use `SecItemCopyMatching` from the Security framework. Reads directly from Keychain — no subprocess spawning, no file I/O. The JSON structure is the same (`claudeAiOauth.accessToken`). First access triggers a one-time Keychain permission dialog where the user clicks "Always Allow".

### 3. `CredentialProvider.readToken()` signature change
**Problem:** After switching to Keychain, `readToken()` no longer throws (Keychain errors are handled internally and return nil). The monitor was still using `try`.

**Resolution:** Removed `try` from the call site in `UsageMonitor.poll()`, updated error message to `"No OAuth token in Keychain. Run: claude login"`.

## Current state

- **Both build paths work:** `swift build` (SPM) and `just app` (xcodegen + xcodebuild)
- **`just run` launches the app** — pie chart icon appears in menu bar, popover opens on click
- **Live data flowing:** Keychain credentials loaded, API returns real usage data (session 37%, weekly 38%, combined forecast ~59%)
- **SQLite database active:** `~/.config/claude-code-usage/history.db` with snapshots and session starts populated
- **Session snapshot persistence:** snapshots survive app restarts (restored from DB on launch)
- **Comprehensive OSLog logging:** all services log with `key=value` pairs and `privacy: .public`, following Osom patterns. Categories: App, Monitor, Credentials, API, Calculator, History, HistoryView
- **Config:** reads `~/.config/claude-code-usage/config.json` (defaults: maxLocalSessions=2, pollIntervalSeconds=300)

## What's working end-to-end

1. App launches as menu bar agent (no Dock icon)
2. Reads OAuth token from macOS Keychain
3. Polls `https://api.anthropic.com/api/oauth/usage` every 5 minutes
4. Computes sessionForecastPct, sessionBudgetUsedPct, combinedPct
5. Renders pie chart icon with 5-tier color scheme
6. Popover shows live gauge bars + historical stats
7. All data persisted in SQLite with 90-day auto-prune
8. Session-reset detection (sessionMinsLeft jumps from <30 to >250)

## Not yet tested / potential follow-ups

- Session-reset detection in production (needs a real 5-hour window boundary)
- Behaviour when Keychain access is denied
- History view with multiple days of accumulated data
- Weekly reset trend query (needs data spanning multiple weeks)
- The `rate_limit_tier` field from the API is captured but not displayed
