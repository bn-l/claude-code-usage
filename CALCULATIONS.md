# Calculations

How the combined usage maximization percentage is derived.

## Data Flow

```
Anthropic API                              SQLite (history.db)
  |                                           |
  |  sessionUsagePct                          |  expectedSessionsPerDay(w)
  |  weeklyUsagePct                           |  (weekday-specific avg from session_starts)
  |  sessionMinsLeft                          |
  |  weeklyMinsLeft                           |
  v                                           v
+-------------------------------------------------+
|              UsageCalculator.compute             |
|                                                  |
|  snapshot (captured at session start):           |
|    weeklyUsagePctAtStart                         |
|    weeklyMinsLeftAtStart                         |
|                                                  |
|  +--------------------+  +--------------------+  |
|  | Session Time       |  | Weekly Allotment   |  |
|  | Maximization       |  | Maximization       |  |
|  +--------------------+  +--------------------+  |
|           \                    /                 |
|            \                  /                  |
|             v                v                   |
|           combinedPct = max(A, B)                |
+-------------------------------------------------+
                      |
                      v
              Menu bar pie chart
```

## Definitions

- `sessionUsagePct` (API) — Session utilization 0-100
- `weeklyUsagePct` (API) — Weekly utilization 0-100
- `sessionMinsLeft` (API) — Minutes until 5h session window resets
- `weeklyMinsLeft` (API) — Minutes until 7d weekly window resets
- `weeklyUsagePctAtStart` (Snapshot) — `weeklyUsagePct` captured at session start
- `weeklyMinsLeftAtStart` (Snapshot) — `weeklyMinsLeft` captured at session start
- `expectedSessionsPerDay(w)` (SQLite) — Average number of claude sessions we observed (and therefore assume were used) on weekday `w`
- `sessionLenMins` (Constant) — `300` (5 hours)
- `eps` (Constant) — `0.01` (prevents division by zero)

## Session Time Maximization

Are you on pace to use the full session?

```
sessionElapsedFrac         = clamp((sessionLenMins - sessionMinsLeft) / sessionLenMins, eps, 1)
sessionTimeMaximizationPct = clamp(sessionUsagePct / sessionElapsedFrac, 0, 100)
```

Example: 2h into a 5h session with 40% usage:
- `sessionElapsedFrac = (300 - 180) / 300 = 0.4`
- `sessionTimeMaximizationPct = 40 / 0.4 = 100%` (on pace for full utilization)

## Weekly Allotment Maximization

Are you using your fair share of weekly budget this session?

```
weeklyBudgetRemainingPct    = max(100 - weeklyUsagePctAtStart, 0)
daysLeftAtStart             = max(weeklyMinsLeftAtStart / 1440, eps)
dailyAllotmentPct           = weeklyBudgetRemainingPct / daysLeftAtStart
expectedSessionAllotmentPct = dailyAllotmentPct / max(expectedSessionsPerDay(w), 1)

weeklyUsageDeltaPct         = max(weeklyUsagePct - weeklyUsagePctAtStart, 0)
weeklyAllotmentMaximizationPct         = clamp(100 * weeklyUsageDeltaPct / max(expectedSessionAllotmentPct, eps), 0, 100)
```

Example: 3 days left, 60% weekly remaining, 2 sessions/day avg for today, delta of 8%:
- `dailyAllotmentPct = 60 / 3 = 20%`
- `expectedSessionAllotmentPct = 20 / 2 = 10%`
- `weeklyAllotmentMaximizationPct = 100 * 8 / 10 = 80%` (used 80% of this session's fair share)

## Combined

```
combinedPct = max(sessionTimeMaximizationPct, weeklyAllotmentMaximizationPct)
```

The tighter constraint wins: session time dominates early in the week; weekly budget dominates late in the week when remaining budget is scarce.

## Session Reset Detection

A new session snapshot is captured when either:

1. **Timer jumped**: `sessionMinsLeft - previousSessionMinsLeft > 30`
2. **Session expired**: wall-clock time since last poll exceeds `previousSessionMinsLeft`

On reset:
```
weeklyUsagePctAtStart <- weeklyUsagePct
weeklyMinsLeftAtStart <- weeklyMinsLeft
```

## Weekly Reset Detection

When `weeklyMinsLeft - previousWeeklyMinsLeft > 60`, the weekly window has reset.
The current session snapshot is re-baselined with the new weekly values.

## expectedSessionsPerDay

Weekday-specific average from `session_starts` table:

1. Count the number sessions on the current weekday across all recorded history
2. If >= 2 distinct days exist for this weekday, return `totalSessions / distinctDays`
3. Otherwise fall back to lifetime average: `totalSessions / daysSinceFirstSession`
4. If no data at all, use `config.defaultSessionsPerDay` (default: 2)

## Color

- `weeklyAllotmentMaximizationPct >= 100`: purple (exceeded weekly session allotment)
- Otherwise: continuous hue interpolation from red (0%) through yellow (50%) to green (100%) based on `combinedPct`
