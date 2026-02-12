# Test Plan

## UsageCalculator

- `compute` with session at start (sessionMinsLeft=300, sessionUsagePct=0): sessionElapsedFrac clamps to eps (0.01), sessionForecastPct = 0/0.01 = 0, combinedPct = 0
- `compute` with session halfway (sessionMinsLeft=150, sessionUsagePct=25): sessionElapsedFrac = 0.5, sessionForecastPct = 50
- `compute` with session nearly over (sessionMinsLeft=1, sessionUsagePct=80): sessionElapsedFrac ≈ 1, sessionForecastPct ≈ 80
- `compute` with sessionMinsLeft=0: sessionElapsedFrac clamps to 1 (not division by zero), sessionForecastPct = sessionUsagePct
- `compute` with sessionUsagePct=100, sessionMinsLeft=150: sessionForecastPct clamps to 100 (not 200)
- `compute` with weeklyUsagePct equal to snapshot.weeklyUsagePctAtStart: weeklyUsageDeltaPct = 0, weeklyBudgetBurnPct = 0
- `compute` with weeklyUsagePct below snapshot.weeklyUsagePctAtStart (e.g. after weekly reset before re-baseline): weeklyUsageDeltaPct clamps to 0 via max(..., 0)
- `compute` with sessionsPerDay=0: max(sessionsPerDay, 1) prevents division by zero in sessionBudgetPctAtStart
- `compute` with sessionsPerDay=0.5 (fractional): sessionBudgetPctAtStart = dailyBudget / 0.5 = 2x daily budget, math is correct
- `compute` with large sessionsPerDay (e.g. 10): per-session budget is tiny, so even small weekly delta yields high weeklyBudgetBurnPct
- `compute` where weeklyBudgetBurnPct exceeds 100 before clamp: result clamps to 100
- `compute` combinedPct is max(sessionForecastPct, weeklyBudgetBurnPct): verify the higher of the two wins
- `compute` with snapshot.weeklyMinsLeftAtStart=0: daysLeftAtStart clamps to eps, dailyBudgetPctAtStart is large but finite
- `compute` with snapshot.weeklyUsagePctAtStart=100 (fully used week): dailyBudgetPctAtStart = 0, sessionBudgetPctAtStart = 0, weeklyBudgetBurnPct = 0/eps clamped

## UsageMonitor — Session Reset Detection

- Timer jumped up by >30 mins (prev=50, current=290): session reset detected, new snapshot created and persisted to session_starts
- Timer jumped up by exactly 30 (prev=100, current=130): no detection (threshold is strictly >30)
- Timer jumped up by 31 (prev=100, current=131): detection fires
- Timer decreased normally (prev=200, current=195): no detection
- No previous value (first poll, previousSessionMinsLeft=nil): no detection, no crash
- App downtime scenario — prev=280 stored 6h ago, current=260 (same-ish high values): delta is -20 so timer-jump misses, but sessionExpired fires because now > prevTimestamp + 280*60
- App downtime scenario — prev=280 stored 2h ago, current=160 (same session continued): sessionExpired = false (280min from 2h ago hasn't elapsed yet), delta = -120, no detection. Correct.
- App downtime scenario — prev=20 stored 25min ago, current=290: both timerJumped (delta=270) and sessionExpired (20min budget elapsed) fire. Snapshot created once, not twice.
- previousSessionMinsLeft, previousWeeklyMinsLeft, and previousPollTimestamp restored from SQLite on launch via latestPollState(): detection works across app restarts
- Session reset creates a SessionSnapshot with current weeklyUsagePct and weeklyMinsLeft, not stale values
- Session reset calls historyStore.saveSessionStart() so it's persisted and counted in expectedSessionsPerDay

## UsageMonitor — Weekly Reset Detection

- weeklyMinsLeft increased by >60 vs previous poll (e.g. prev=10, current=10080): weekly reset detected, snapshot re-baselined and persisted
- weeklyMinsLeft increased by exactly 60 (prev=100, current=160): no detection (threshold is strictly >60)
- weeklyMinsLeft increased by 61 (prev=100, current=161): detection fires
- weeklyMinsLeft decreased normally (prev=5000, current=4995): no detection
- No previous weekly value (first poll, previousWeeklyMinsLeft=nil): no detection, no crash
- Near-week-start scenario — snapshot was at weeklyMinsLeftAtStart=9900, prev poll at 5, current=10080: detected because 10080-5=10075 > 60 (compares with last poll, not snapshot)
- Low baseline usage scenario — weeklyUsagePctAtStart=5, prev=10, reset to 10080: detected (compares timer, not usage %)
- previousWeeklyMinsLeft restored from SQLite on launch via latestPollState(): detection works across app restarts
- Weekly reset re-baselines currentSnapshot with new weeklyUsagePct and weeklyMinsLeft
- Weekly reset persists via updateLatestSessionStart() (UPDATE, not INSERT) so the re-baseline survives app restarts without inflating session counts
- Weekly reset does NOT set currentSnapshot to nil (it replaces, not clears)
- Weekly re-baseline does NOT increase session_starts row count (expectedSessionsPerDay unaffected)
- Both session-reset and weekly-reset fire in same poll (e.g. long downtime crossing week boundary): only one session_starts row created — session-reset INSERTs, weekly-reset UPDATEs that same row
- Weekly re-baseline with empty session_starts table: falls back to INSERT (edge case on first launch)

## UsageMonitor — Bootstrap Snapshot

- First launch, no data in SQLite: currentSnapshot is nil, bootstrap creates one from current API values
- Bootstrap snapshot is NOT persisted via saveSessionStart() — does not inflate expectedSessionsPerDay
- Bootstrap snapshot is used for UsageCalculator.compute() (currentSnapshot! doesn't crash)
- Second launch with existing session_starts data: currentSnapshot restored from DB, bootstrap does not fire

## UsageMonitor — Polling

- startPolling calls poll() immediately before entering the loop
- Poll loop interval matches config.pollIntervalSeconds (default 300s)
- manualPoll() triggers a single poll and returns
- isLoading is true during poll and false after (including on error)
- lastUpdated is set after successful poll
- lastError is cleared on successful poll
- lastError is set on API failure (network error, non-200 status)
- lastError is set when no Keychain token found
- Each poll persists the computed snapshot via historyStore.saveSnapshot()
- Each poll calls historyStore.pruneOldRecords()

## UsageMonitor — sessionsPerDay Resolution

- With observed data from expectedSessionsPerDay(): uses observed value
- Without observed data (nil): falls back to Double(config.defaultSessionsPerDay)
- Without observed data and defaultSessionsPerDay=10: sessionsPerDay=10, making sessionBudgetPctAtStart very small, so even modest usage yields weeklyBudgetBurnPct near 100 — verify the budget calculation is not unreasonably lenient or strict when the fallback is high
- expectedSessionsPerDay error (throws): falls back to config (try? handles it)

## UsageMonitor — minutesUntil

- Valid ISO8601 with fractional seconds: returns correct positive minutes
- Valid ISO8601 without fractional seconds: falls back and parses correctly
- Date in the past: returns 0 (clamped via max(..., 0))
- nil input: returns 0
- Malformed string: returns 0

## HistoryStore — Persistence

- saveSnapshot inserts a row into usage_snapshots with all fields mapped correctly
- saveSnapshot round-trip via raw SQL: insert via saveSnapshot, then SELECT weekly_budget_burn_pct from usage_snapshots — value must equal the weeklyBudgetBurnPct passed in (catches CodingKey-to-column mismatch; verifies raw SQL queries like budgetHitRate reference the correct column)
- saveSessionStart inserts a row into session_starts with correct field mapping
- latestSessionStart returns the most recent session_starts record as a SessionSnapshot
- latestSessionStart returns nil when table is empty
- latestPollState returns (sessionMinsLeft, weeklyMinsLeft, timestamp) from most recent usage_snapshots row
- latestPollState returns nil when table is empty
- pruneOldRecords deletes usage_snapshots older than 90 days
- pruneOldRecords deletes session_starts older than 90 days
- pruneOldRecords leaves records younger than 90 days untouched
- Migration v1 creates both tables and indexes without error on fresh DB
- Migration v2 renames session_budget_used_pct column to weekly_budget_burn_pct without error
- Migration v1+v2 on fresh DB: both run sequentially without error, final schema has weekly_budget_burn_pct column
- Migration v2 on existing DB with data: column rename preserves all existing row values

## HistoryStore — History Queries

- todayStats returns sessionCount from session_starts created today only (not yesterday)
- todayStats returns avgCombinedPct from usage_snapshots created today
- todayStats with no data today: sessionCount=0, avgCombinedPct=0
- dailyMaxCombined returns one entry per day with the max combined_pct
- dailyMaxCombined respects the days parameter (default 7)
- dailyMaxCombined results are ordered by date ascending
- budgetHitRate returns percentage of snapshots where weekly_budget_burn_pct >= 100
- budgetHitRate with zero snapshots: returns 0 (not division by zero)
- peakUsageHours returns top N hours by avg combined_pct
- peakUsageHours hour values are 0-23 integers
- weeklyResetTrend groups by ISO year-week (%Y-%W) and returns max weekly_usage_pct per week
- weeklyResetTrend determinism: insert snapshots on Mon, Wed, Fri of same ISO week, call weeklyResetTrend twice — returned `date` must be identical both times (MAX aggregation guarantees this)
- weeklyResetTrend date consistency: insert snapshots on Mon and Fri of same week — returned date is MAX date within the group (Friday)
- weeklyResetTrend year boundary: snapshots in week 1 of 2025 and week 1 of 2026 are grouped separately (%Y-%W, not just %W)
- avgSessionsPerDay divides session count by distinct days in the window

## HistoryStore — expectedSessionsPerDay

- With >= 2 distinct days for current weekday: returns weekday-specific average (total sessions on that weekday / distinct days)
- With 1 distinct day for current weekday but lifetime data exists: falls back to lifetime average (total / days since first)
- With no session_starts at all: returns nil
- Weekday mapping: Swift Calendar.weekday-1 matches SQLite strftime('%w') (0=Sunday)
- Lifetime fallback: daysSinceFirst clamps to min 1 (no division by zero on first day)
- Single session on first day: returns 1.0 (1 session / 1 day)

## CredentialProvider

- Reads token from Keychain service "Claude Code-credentials"
- Parses JSON → claudeAiOauth → accessToken
- Returns nil when Keychain item doesn't exist (errSecItemNotFound)
- Returns nil when Keychain data is not valid JSON
- Returns nil when claudeAiOauth key is missing
- Returns nil when accessToken key is missing within claudeAiOauth

## UsageAPIClient

- Sends GET to https://api.anthropic.com/api/oauth/usage
- Sets Authorization header to "Bearer <token>"
- Sets anthropic-beta header to "oauth-2025-04-20"
- Decodes valid JSON response into UsageLimits with five_hour and seven_day
- Handles response where five_hour is null: UsageLimits.five_hour is nil
- Handles response where seven_day is null: UsageLimits.seven_day is nil
- Throws on non-200 HTTP status
- Throws on non-HTTP response

## APIResponse (Codable)

- UsageWindow decodes utilization as Double (not Int) — values like 37.5 parse correctly
- UsageWindow decodes resets_at as String
- UsageLimits decodes rate_limit_tier as optional String
- UsageLimits handles missing five_hour/seven_day gracefully (nil)
- Utilization values are on 0–100 percent scale (not 0–1 fractional): a response with utilization=50.0 means 50%, and UsageCalculator math produces correct results without rescaling

## ColorTier

- combinedPct=0 → .red
- combinedPct=20 → .red (boundary: ...20 includes 20)
- combinedPct=21 → .orange
- combinedPct=50 → .orange (boundary)
- combinedPct=51 → .blue
- combinedPct=70 → .blue (boundary)
- combinedPct=71 → .purple
- combinedPct=90 → .purple (boundary)
- combinedPct=91 → .green
- combinedPct=100 → .green
- combinedPct=-5 → .red (negative values fall into ...20)
- combinedPct=150 → .green (over-100 falls into default)
- cgColor is derived from color via NSColor(color).cgColor (not independently specified)

## PieChartIcon

- combinedPct=0: rendered image has visible pixels (background circle outline) so the menu bar icon is never invisible
- combinedPct=50: arc sweeps 180 degrees (half circle)
- combinedPct=100: arc sweeps full 360 degrees (full circle)
- Arc starts from 12 o'clock position (startAngle = pi/2 in CG coords)
- Arc sweeps clockwise (CG clockwise = true)
- Image is 18x18 points
- isTemplate is false (actual colors, not monochrome)
- Fill color matches ColorTier for the given combinedPct

## AppConfig

- Missing config file: returns defaults (defaultSessionsPerDay=2, pollIntervalSeconds=300)
- Valid config.json with both fields (defaultSessionsPerDay, pollIntervalSeconds): returns parsed values
- Partial config.json (only one field): Codable defaults fill missing fields
- Malformed JSON: returns defaults (no crash)
- Config file location: ~/.config/claude-code-usage/config.json

## PopoverView

- Shows MetricsView + HistoryView when monitor.metrics is non-nil
- Shows error state (exclamationmark.triangle + error text) when monitor.lastError is set and metrics is nil
- Shows ProgressView("Loading...") when both metrics and lastError are nil
- Refresh button calls monitor.manualPoll()
- Refresh button shows ProgressView spinner while monitor.isLoading is true
- Refresh button is disabled while monitor.isLoading is true
- "Updated X ago" shows relative time from monitor.lastUpdated
- Quit button terminates the application
- Popover width is 320 points

## MetricsView

- Combined gauge uses colorTier.color (tier-based)
- Session Forecast gauge uses ColorTier(combinedPct: sessionForecastPct).color (tier-based)
- Session gauge uses fixed ColorTier.blue.color
- Weekly gauge uses fixed ColorTier.purple.color
- Session detail shows "Xh Ym remaining" formatted from sessionMinsLeft
- Weekly detail shows "Xd Yh Zm until reset" formatted from weeklyMinsLeft
- Weekly detail omits days when < 1 day remaining
- GaugeRow bar width is proportional to value/100, clamped to max 1.0
- GaugeRow percentage text is displayed as integer (Int(value))

## HistoryView

- Refreshes data when monitor.lastUpdated changes (via .task(id:))
- Shows today's session count and avg usage when todayStats is non-nil
- 7-day trend bars: height proportional to maxCombinedPct, color from ColorTier
- 7-day trend bar labels show day-of-month (last 2 chars of date string)
- Budget hit rate displayed as integer percentage
- Avg sessions/day displayed with 1 decimal place
- Peak hours formatted as "HH:00" joined by ", "
- Peak hours section hidden when peakHours is empty
- Gracefully handles nil historyStore (loadHistory returns early)

## HistoryStore — Timezone Correctness

These tests catch Issue #11 (strftime UTC vs local time). All require inserting snapshots with known timestamps and verifying results against local timezone expectations. Run in a non-UTC timezone (e.g. TZ=America/Los_Angeles) to be meaningful.

- peakUsageHours local hour: insert a snapshot at 2026-01-15T22:00:00Z (= 14:00 PST). peakUsageHours should return hour=14, not hour=22
- dailyMaxCombined local date boundary: insert two snapshots — one at 2026-01-15T07:30:00Z (Jan 14 23:30 PST) and one at 2026-01-15T08:30:00Z (Jan 15 00:30 PST). dailyMaxCombined should group them into two different local days (Jan 14 and Jan 15), not the same UTC day (Jan 15)
- expectedSessionsPerDay weekday match: insert session_starts on known UTC timestamps that span a local-time weekday boundary. Verify the weekday filter matches local weekday, not UTC weekday. E.g. a session at 2026-01-14T06:00:00Z is Monday UTC but Sunday PST — should count as Sunday
- todayStats vs dailyMaxCombined consistency: insert a snapshot at 00:30 local time (which is a different UTC date for negative-offset timezones). Verify todayStats includes it (uses Swift Calendar, local-aware) and dailyMaxCombined also includes it under today's date
- avgSessionsPerDay local date grouping: insert 3 session_starts that fall on 2 distinct local dates but only 1 distinct UTC date. avgSessionsPerDay should divide by 2 (local days), not 1 (UTC day)
- weeklyResetTrend local week grouping: insert snapshots near a local-time week boundary (e.g. Sunday 23:30 local = Monday UTC). Verify grouping uses local week, not UTC week
