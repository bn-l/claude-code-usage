I get given the following data from anthropic on claude code's usage:

- Current session usage percentage
- Hours and minutes remaining before the current session resets
- Weekly usage percentage
- Day and time weekly usage resets

----

Combined percentage maths:

Defs:
clamp(x, lo, hi) = min(max(x, lo), hi)
eps = 0.01

Inputs (now):
sessionUsagePct
weeklyUsagePct
sessionMinsLeft
weeklyMinsLeft
sessionLenMins = 5 * 60
sessionsPerDay = observed avg from history (fallback: config maxLocalSessions, default 2)

Session-start snapshots (capture when we notice the sessionMinsLeft suddenly get close to zero and then ):
weeklyUsagePctAtStart
weeklyMinsLeftAtStart

sessionElapsedFrac =
  clamp((sessionLenMins - sessionMinsLeft) / sessionLenMins, eps, 1)

sessionForecastPct =
  clamp(sessionUsagePct / sessionElapsedFrac, 0, 100)

daysLeftAtStart =
  max(weeklyMinsLeftAtStart / 1440, eps)

dailyBudgetPctAtStart =
  max(100 - weeklyUsagePctAtStart, 0) / daysLeftAtStart

sessionBudgetPctAtStart =
  dailyBudgetPctAtStart / max(sessionsPerDay, 1)

weeklyUsageDeltaPct =
  max(weeklyUsagePct - weeklyUsagePctAtStart, 0)

weeklyBudgetBurnPct =
  clamp(
    100 * weeklyUsageDeltaPct / max(sessionBudgetPctAtStart, eps),
    0,
    100
  )

combinedPct =
  max(sessionForecastPct, weeklyBudgetBurnPct)

On new session start:
weeklyUsagePctAtStart = weeklyUsagePct
weeklyMinsLeftAtStart = weeklyMinsLeft

sessionsPerDay calculation:
sessionsPerDay = totalSessionsObserved / daysSinceFirstObservation
(auto-calculated from session_starts table in SQLite, falls back to config maxLocalSessions)
