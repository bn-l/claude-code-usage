# Calculations (New Algorithm)

How the EWMA-based pacing engine produces a calibrator signal.

## Data Flow

```
Anthropic API                           JSON Store (usage_data.json)
  |                                      |
  |  sessionUsage (%)                    |  polls[] (timestamped history)
  |  sessionRemaining (min)              |  sessions[] (boundary markers)
  |  weeklyUsage (%)                     |
  |  weeklyRemaining (min)               |
  v                                      v
+------------------------------------------------------------+
|                  UsageOptimiser.recordPoll                 |
|                                                            |
|  Stage 1: weeklyDeviation ───────────────────────┐          |
|    weeklyExpected  (empirical or schedule-based) |         |
|    weeklyProjected (velocity extrapolation)      |         |
|                                    ┌─────────────┘         |
|                                    v                       |
|  Stage 2: sessionTarget ← f(deviation)                     |
|           sessionBudget ← weeklyRemaining / sessionsLeft   |
|                                    |                       |
|                                    v                       |
|  Stage 3: optimalRate ← min(targetRate, ceilingRate,       |
|                              budgetRate)                   |
|                                    |                       |
|                                    v                       |
|  Stage 4: calibrator ← (velocity - optimalRate)            |
|                          / optimalRate                     |
+------------------------------------------------------------+
                         |
                         v
               Menu bar calibrator icon
         (center line = on pace; bar extends
          up = too fast, down = too slow)
```

## Definitions

| Symbol | Source | Description |
|---|---|---|
| `sessionUsage` | API | Session utilization 0–100 |
| `sessionRemaining` | API | Minutes until 5h session window resets |
| `weeklyUsage` | API | Weekly utilization 0–100 |
| `weeklyRemaining` | API | Minutes until 7d weekly window resets |
| `sessionMinutes` | Constant | `300` (5 hours) |
| `weekMinutes` | Constant | `10080` (7 days) |
| `emaAlpha` | Constant | `0.3` (EWMA smoothing factor) |
| `gapThreshold` | Constant | `15` min (max inter-poll gap for velocity) |
| `boundaryJump` | Constant | `30` min (session reset detection threshold) |

## Session Boundary Detection

A new session is recorded when any of:

1. **First poll ever** — bootstrap
2. **Timer jumped**: `sessionRemaining - previous.sessionRemaining > 30`
3. **Session expired**: wall-clock minutes since last poll `> previous.sessionRemaining`

On detection, a `SessionStart` is appended with the current `weeklyUsage` and `weeklyRemaining`.

## Stage 1: Weekly Deviation

*How far off-pace are you from ideal weekly consumption?*

Produces a value in **[-1, 1]** via `tanh` compression. Positive = behind (should use more), negative = ahead (should ease off).

### Expected Usage

What `weeklyUsage` _should_ be at the current elapsed point in the week:

```
elapsedMinutes = weekMinutes - weeklyRemaining
```

**Empirical path** (preferred, requires 3+ weeks of data):

```
candidates = historical polls where:
  - poll is older than 7 days (excludes current week)
  - |elapsed(poll) - elapsedMinutes| < 15 min
expected = median(candidates.weeklyUsage)        // needs >= 5 samples
```

**Schedule-based fallback**:

```
weekStart   = now - elapsedMinutes
weekEnd     = now + weeklyRemaining
activeElapsed = activeHoursInRange(weekStart, now)
activeTotal   = activeHoursInRange(weekStart, weekEnd)
expected      = min(100, activeElapsed / activeTotal * 100)
```

### Projected End-of-Week Usage

If at least 0.5 active hours have elapsed, extrapolate from the current average rate:

```
activeElapsed   = activeHoursInRange(weekStart, now)
activeRemaining = activeHoursInRange(now, weekEnd)
averageRate     = weeklyUsage / activeElapsed
projected       = weeklyUsage + averageRate * activeRemaining
```

### Combining Into Deviation

```
positional        = (expected - weeklyUsage) / 100
velocityDeviation = (100 - projected) / 100

         ┌ tanh(2 * (0.5 * positional + 0.5 * velocityDeviation))   if projected available
deviation│
         └ tanh(2 * positional)                                      otherwise
```

The `tanh(2x)` squashes the raw signal into [-1, 1] with a gentle response near zero — small deviations don't cause the calibrator to flip-flop, while large deviations still saturate toward ±1.

Example: expected 40%, actual 35%, projected 85%:
- `positional = (40 - 35) / 100 = 0.05`
- `velocityDeviation = (100 - 85) / 100 = 0.15`
- `raw = 0.5 * 0.05 + 0.5 * 0.15 = 0.10`
- `deviation = tanh(0.2) = 0.20` (slightly behind — use more)

## Stage 2: Session Target & Budget

### Session Target

Deviation scales the session utilization target:

```
sessionTarget = 100 * clamp(1 + deviation, 0.1, 1.0)
```

| Deviation | Target | Meaning |
|---|---|---|
| 0 | 100% | On pace — use the full session |
| -0.5 | 50% | Ahead — only need half the session |
| -0.9 | 10% | Way ahead — barely use the session |
| +0.5 | 100% | Behind — use everything (capped) |

The target can only be lowered (not raised above 100%), since you can't retroactively recover missed usage by exceeding a single session.

### Session Budget

A weekly-budget constraint on how much session% this session should consume.

```
exchangeRate  = median(Δ weeklyUsage / Δ sessionUsage)    // see Exchange Rate
remainingHrs  = activeHoursInRange(now, weekEnd)
sessionsLeft  = max(remainingHrs / 5, 1)
sessionBudget = max(100 - weeklyUsage, 0) / sessionsLeft
```

Only available when the exchange rate has enough samples (see below).

## Stage 3: Optimal Rate

*The consumption rate (%/minute) you should sustain for the rest of this session.*

```
tau         = max(sessionRemaining, 0.1)
targetRate  = max((sessionTarget - sessionUsage) / tau, 0)
ceilingRate = max((100 - sessionUsage) / tau, 0)
rate        = min(targetRate, ceilingRate)
```

If exchange rate and session budget are available, a budget-derived ceiling is applied:

```
budgetRate = max(sessionBudget / (exchangeRate * tau), 0)
rate       = min(rate, budgetRate)
```

The optimal rate is the most conservative of three constraints: hit the target, don't exceed 100%, and don't overspend the weekly budget.

## Stage 4: Calibrator

*The final output: a value in **[-1, 1]** indicating pacing direction.*

```
velocity = EMA velocity from session polls (see below)
         | fallback: sessionUsage / max(elapsed, 0.1)   if elapsed >= 5 min

if sessionRemaining <= 0:
    calibrator = 0

elif optimalRate < 1e-6:
    calibrator = 1 if velocity > 1e-6 else 0

else:
    calibrator = clamp((velocity - optimalRate) / optimalRate, -1, 1)
```

| Calibrator | Menu bar | Meaning |
|---|---|---|
| 0 | Center line only | On pace |
| +1 | Full bar above center (red) | Consuming too fast — ease off |
| -1 | Full bar below center (red) | Consuming too slowly — use more |
| ~0 | Small/no bar (green) | Close to optimal |

## Velocity Estimation (EWMA)

Session velocity tracks how fast `sessionUsage` is changing, smoothed exponentially:

```
for each consecutive poll pair within current session:
    if gap > 15 min: skip (poll gap too large)
    instant = Δ sessionUsage / Δ minutes
    ema     = 0.3 * instant + 0.7 * previous_ema    // first valid pair seeds the EMA
```

Requires at least 2 polls in the session with a valid gap. Falls back to simple average if unavailable, but only after 5 minutes of elapsed session time.

## Exchange Rate

The ratio of weekly% consumed per session% consumed, estimated from historical poll-to-poll deltas:

```
for each consecutive poll pair (not spanning a session boundary):
    if gap > 15 min: skip
    if Δ sessionUsage > 0.5:
        ratio = Δ weeklyUsage / Δ sessionUsage

exchangeRate = median(ratios)    // requires >= 10 samples
```

This bridges the two percentage scales: session% and weekly% are not on the same scale, and the exchange rate lets the optimiser translate session budget into session-% terms.

## Active Hours Schedule

Active hours define when you're expected to be using Claude, used for projecting expected usage and computing remaining session slots.

### Initial

Set from config (default: 10:00–20:00 every day = 10h/day):

```json
// ~/.config/claude-code-usage/config.json
{
  "activeHoursPerDay": [10, 10, 10, 10, 10, 10, 10]
}
```

Array index: 0 = Monday, ..., 6 = Sunday. Each value becomes a window `[10:00, 10:00 + hours]`.

### Auto-Detection

After 7+ days of data, windows are refined per-weekday from observed activity:

```
for each weekday:
    collect hours-of-day from polls where Δ sessionUsage > 0.5
    if >= 3 such polls:
        window = [min(hours) - 1h, max(hours) + 1h]    // clamped to [0, 24], min span 2h
```

### Range Calculation

`activeHoursInRange(from, to)` walks day-by-day, computing the overlap between each day's active window and the query range, summing hours.

## Color

Green at center (on pace), red at extremes (off pace in either direction):

```
magnitude = clamp(|calibrator|, 0, 1)
hue       = (1 - magnitude) * 120 / 360    // 120° = green, 0° = red
color     = HSB(hue, saturation: 0.6, brightness: 0.925)
```

The color is symmetric — consuming too fast and too slowly both shift toward red. Only the bar direction (up/down) distinguishes the two.

## Data Management

- **Storage**: `~/.config/claude-code-usage/usage_data.json` — JSON with `polls[]` and `sessions[]`, dates as seconds-since-epoch
- **Pruning**: Records older than 90 days are discarded after every poll
- **Persistence**: Written atomically after every `recordPoll` call

## Key Differences From Old Algorithm

| Aspect | Old | New |
|---|---|---|
| Output | Utilization % (0–100) | Calibrator signal (-1 to +1) |
| Approach | Two parallel paths, take max | Four-stage pipeline |
| Velocity | Not tracked | EWMA-smoothed consumption rate |
| Weekly model | Snapshot at session start | Continuous empirical + schedule-based expected curve |
| Session target | Always 100% | Dynamically lowered by weekly deviation |
| Budget constraint | Per-session allotment from remaining days | Exchange-rate-derived budget per remaining active session |
| Active hours | Not modeled | Per-weekday windows, auto-detected from history |
| Color | Red→Yellow→Green (low→high utilization) | Green→Red by magnitude (on-pace→off-pace) |
| Icon | Pie chart | Vertical bar (up = fast, down = slow) |
