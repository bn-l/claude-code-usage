from __future__ import annotations

from math import tanh

from constants import (
    ACTIVE_END, ACTIVE_START, BOUNDARY_JUMP, EMA_ALPHA, GAP_THRESHOLD,
    SESSION_MIN, WEEK_MIN, Poll,
)


# ════════════════════════════════════════════════════════════════════════
#  SHARED HELPERS
# ════════════════════════════════════════════════════════════════════════


def detect_boundary(poll: Poll, prev: Poll | None) -> bool:
    if prev is None:
        return True
    if poll.sr - prev.sr > BOUNDARY_JUMP:
        return True
    if (poll.t - prev.t) > prev.sr:
        return True
    return False


def active_hours_in_range(start_min: float, end_min: float) -> float:
    total = 0.0
    cursor = start_min
    while cursor < end_min:
        day_base = (cursor // 1440) * 1440
        w_open = day_base + ACTIVE_START * 60
        w_close = day_base + ACTIVE_END * 60
        next_day = day_base + 1440
        seg_end = min(end_min, next_day)
        o_start = max(cursor, w_open)
        o_end = min(seg_end, w_close)
        if o_end > o_start:
            total += (o_end - o_start) / 60
        cursor = next_day
    return total


def weekly_expected(poll: Poll) -> float:
    elapsed = WEEK_MIN - poll.wr
    week_start_t = poll.t - elapsed
    week_end_t = poll.t + poll.wr
    ae = active_hours_in_range(week_start_t, poll.t)
    at = active_hours_in_range(week_start_t, week_end_t)
    return min(100.0, (ae / at) * 100) if at > 0 else 0.0


def weekly_projected(poll: Poll) -> float | None:
    elapsed = WEEK_MIN - poll.wr
    week_start_t = poll.t - elapsed
    week_end_t = poll.t + poll.wr
    ae = active_hours_in_range(week_start_t, poll.t)
    if ae < 0.5:
        return None
    ar = active_hours_in_range(poll.t, week_end_t)
    return poll.wu + (poll.wu / ae) * ar


def weekly_deviation(poll: Poll) -> float:
    if poll.wr <= 0:
        return 0.0
    exp = weekly_expected(poll)
    positional = (exp - poll.wu) / 100
    proj = weekly_projected(poll)
    if proj is not None:
        vel_dev = (100 - proj) / 100
        return tanh(2 * (0.5 * positional + 0.5 * vel_dev))
    return tanh(2 * positional)


def session_target(deviation: float) -> float:
    return 100.0 * max(0.1, min(1.0, 1.0 + deviation))


def ema_velocity(session_polls: list[Poll]) -> float | None:
    if len(session_polls) < 2:
        return None
    ema = None
    for j in range(1, len(session_polls)):
        dt = session_polls[j].t - session_polls[j - 1].t
        if dt <= 0 or dt > GAP_THRESHOLD:
            continue
        instant = (session_polls[j].su - session_polls[j - 1].su) / dt
        ema = instant if ema is None else EMA_ALPHA * instant + (1 - EMA_ALPHA) * ema
    return ema


def rate_calibrator(poll: Poll, velocity: float | None) -> float:
    """Compute calibrator given velocity, using Current's rate framework."""
    dev = weekly_deviation(poll)
    tgt = session_target(dev)
    if poll.sr <= 0:
        return 0.0
    tau = max(poll.sr, 0.1)
    optimal = min(max((tgt - poll.su) / tau, 0), max((100 - poll.su) / tau, 0))
    elapsed = SESSION_MIN - poll.sr
    if velocity is None:
        if elapsed < 5:
            return 0.0
        velocity = poll.su / max(elapsed, 0.1)
    vel = max(velocity, 0.0)
    if optimal < 1e-6:
        return 1.0 if vel > 1e-6 else 0.0
    return max(-1.0, min(1.0, (vel - optimal) / optimal))
