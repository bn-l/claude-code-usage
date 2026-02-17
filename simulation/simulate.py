#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy"]
# ///
"""
Monte Carlo simulation comparing calibrator algorithms.

Part 1: Open-loop — fixed usage patterns, measure signal quality
Part 2: Closed-loop — calibrator feeds back into user behavior, measure outcomes

Run:  uv run simulate.py
"""

from __future__ import annotations

import io
import multiprocessing
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from math import tanh

import numpy as np

# ── Constants (mirroring UsageOptimiser.swift) ──────────────────────────

SESSION_MIN = 300.0
WEEK_MIN = 10080.0
POLL_INTERVAL = 5.0  # minutes
EMA_ALPHA = 0.3
BOUNDARY_JUMP = 30.0
GAP_THRESHOLD = 15.0
EXCHANGE_RATE = 0.12  # weekly% per session%
ACTIVE_START = 10.0  # hour
ACTIVE_END = 20.0  # hour
N_OPEN_RUNS = 500
N_CLOSED_RUNS = 200
COMPLIANCE_GAIN = 0.7  # max rate modulation from calibrator
FATIGUE_RATE = 0.003  # compliance decay per consecutive saturated tick
FATIGUE_FLOOR = 0.85  # minimum fatigue multiplier (15% max reduction)
FATIGUE_SAT = 0.9  # |cal| above this counts as saturated for fatigue
N_WORKERS = min(os.cpu_count() or 4, 8)
_MP_CTX = multiprocessing.get_context("fork")


# ── Data ────────────────────────────────────────────────────────────────


@dataclass(slots=True)
class Poll:
    t: float  # minutes from week start
    su: float  # session usage %
    sr: float  # session remaining min
    wu: float  # weekly usage %
    wr: float  # weekly remaining min


# ════════════════════════════════════════════════════════════════════════
#  USAGE PROFILES
# ════════════════════════════════════════════════════════════════════════


# ── Organic ────────────────────────────────────────────────────────


def _bursty(rng, elapsed, _sn, _d, _h):
    base = 2.5 * np.exp(-elapsed / 45)
    return max(0.0, base + rng.exponential(0.2))


def _steady(rng, _e, _sn, _d, _h):
    return max(0.0, rng.normal(0.33, 0.06))


def _ramp_up(rng, elapsed, _sn, _d, _h):
    ramp = 1 / (1 + np.exp(-(elapsed - 40) / 12))
    return max(0.0, 0.45 * ramp + rng.normal(0, 0.04))


def _sporadic(rng, _e, _sn, _d, _h):
    if rng.random() < 0.15:
        return max(0.0, rng.normal(1.5, 0.4))
    return max(0.0, rng.exponential(0.03))


def _heavy(rng, _e, _sn, _d, _h):
    return max(0.0, rng.normal(0.55, 0.12))


def _light(rng, _e, _sn, _d, _h):
    return 0.0 if rng.random() > 0.35 else max(0.0, rng.normal(0.12, 0.04))


def _end_week_crunch(rng, _e, _sn, day, _h):
    base = 0.15 if day < 3 else 0.55
    return max(0.0, rng.normal(base, 0.08))


# ── Stress ─────────────────────────────────────────────────────────


def _taper_off(rng, elapsed, _sn, _d, _h):
    """Heavy first 2h then nearly idle — session-tail bug."""
    if elapsed < 120:
        return max(0.0, rng.normal(0.6, 0.1))
    return max(0.0, rng.exponential(0.02))


def _cold_burst(rng, elapsed, _sn, _d, _h):
    """Explosive first 10 min then normal — EWMA startup spike."""
    if elapsed < 10:
        return max(0.0, rng.normal(3.0, 0.5))
    return max(0.0, rng.normal(0.25, 0.06))


def _weekend_warrior(rng, _e, _sn, day, _h):
    """Zero Mon-Thu, heavy Fri-Sun."""
    if day < 4:
        return 0.0
    return max(0.0, rng.normal(0.7, 0.15))


def _stop_start(rng, elapsed, _sn, _d, _h):
    """20-min work / 20-min idle cycles."""
    if (elapsed % 40) < 20:
        return max(0.0, rng.normal(0.8, 0.15))
    return 0.0


def _one_big_session(rng, _e, sn, _d, _h):
    """First session heavy, second idle."""
    if sn % 2 == 0:
        return max(0.0, rng.normal(0.6, 0.1))
    return max(0.0, rng.exponential(0.02))


PROFILES = {
    "Bursty": _bursty, "Steady": _steady, "Ramp-up": _ramp_up,
    "Sporadic": _sporadic, "Heavy": _heavy, "Light": _light,
    "End-week crunch": _end_week_crunch,
    "STRESS Taper-off": _taper_off, "STRESS Cold burst": _cold_burst,
    "STRESS Weekend warrior": _weekend_warrior,
    "STRESS Stop-start": _stop_start, "STRESS One-big-session": _one_big_session,
}


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


def _rate_calibrator(poll: Poll, velocity: float | None) -> float:
    """Shared: compute calibrator given velocity, using Current's rate framework."""
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


# ════════════════════════════════════════════════════════════════════════
#  PART 1: OPEN-LOOP
# ════════════════════════════════════════════════════════════════════════

# ── Batch algorithms ───────────────────────────────────────────────────


def run_current(polls: list[Poll]) -> list[float]:
    cals: list[float] = []
    session_polls: list[Poll] = []

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)

        if p.sr <= 0:
            cals.append(0.0)
            continue

        tau = max(p.sr, 0.1)
        optimal = min(max((tgt - p.su) / tau, 0), max((100 - p.su) / tau, 0))

        velocity = ema_velocity(session_polls)
        elapsed = SESSION_MIN - p.sr
        if velocity is None:
            if elapsed < 5:
                cals.append(0.0)
                continue
            velocity = p.su / max(elapsed, 0.1)

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            cals.append(1.0 if vel > 1e-6 else 0.0)
        else:
            cals.append(max(-1.0, min(1.0, (vel - optimal) / optimal)))

    return cals


def run_path_a(polls: list[Poll]) -> list[float]:
    cals: list[float] = []
    session_polls: list[Poll] = []

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)

        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        tau = max(p.sr, 0.1)
        optimal = min(max((tgt - p.su) / tau, 0), max((100 - p.su) / tau, 0))

        raw_vel = ema_velocity(session_polls)
        if raw_vel is None:
            if elapsed < 5:
                cals.append(0.0)
                continue
            velocity = p.su / max(elapsed, 0.1)
        else:
            avg_vel = p.su / max(elapsed, 0.1)
            frac = min(elapsed / 60.0, 1.0)
            velocity = frac * raw_vel + (1 - frac) * avg_vel

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            rate_cal = 1.0 if vel > 1e-6 else 0.0
        else:
            rate_cal = max(-1.0, min(1.0, (vel - optimal) / optimal))

        s_frac = p.sr / SESSION_MIN
        weekly_cal = -dev
        cal = max(-1.0, min(1.0, s_frac * rate_cal + (1 - s_frac) * weekly_cal))
        cals.append(cal)

    return cals


def run_path_b(polls: list[Poll]) -> list[float]:
    cals: list[float] = []

    for i, p in enumerate(polls):
        dev = weekly_deviation(p)
        tgt = session_target(dev)

        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        if elapsed < 5:
            cals.append(0.0)
            continue

        expected_su = tgt * (elapsed / SESSION_MIN)
        session_err = (p.su - expected_su) / max(tgt, 1.0)

        s_frac = p.sr / SESSION_MIN
        weekly_signal = -dev
        cal = max(-1.0, min(1.0, s_frac * session_err + (1 - s_frac) * weekly_signal))
        cals.append(cal)

    return cals


def run_holt(polls: list[Poll]) -> list[float]:
    """A2: Holt's double exponential smoothing for velocity."""
    cals: list[float] = []
    session_polls: list[Poll] = []
    s: float | None = None
    b: float = 0.0

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
            s = None
            b = 0.0
        session_polls.append(p)

        if len(session_polls) >= 2:
            pp = session_polls[-2]
            dt = p.t - pp.t
            if 0 < dt <= GAP_THRESHOLD:
                iv = (p.su - pp.su) / dt
                if s is None:
                    s = iv
                    b = 0.0
                else:
                    s_new = 0.3 * iv + 0.7 * (s + b)
                    b = 0.1 * (s_new - s) + 0.9 * b
                    s = s_new

        cals.append(_rate_calibrator(p, s))
    return cals


def run_alpha_beta(polls: list[Poll]) -> list[float]:
    """A3: Alpha-beta filter for joint position+velocity tracking."""
    cals: list[float] = []
    x: float = 0.0
    v: float | None = None
    last_t: float | None = None

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            x = p.su
            v = None
            last_t = p.t
            cals.append(_rate_calibrator(p, v))
            continue

        dt = p.t - last_t if last_t is not None else 0.0
        if 0 < dt <= GAP_THRESHOLD and v is not None:
            x_pred = x + v * dt
            residual = p.su - x_pred
            x = x_pred + 0.2 * residual
            v = v + (0.1 / dt) * residual
        elif 0 < dt <= GAP_THRESHOLD and v is None:
            x_pred = x
            residual = p.su - x_pred
            x = x_pred + 0.2 * residual
            v = (0.1 / dt) * residual
        else:
            x = p.su
            v = None

        last_t = p.t
        cals.append(_rate_calibrator(p, v))
    return cals


def run_pid(polls: list[Poll]) -> list[float]:
    """C2: Classical PID controller."""
    cals: list[float] = []
    integral = 0.0
    prev_error = 0.0

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            integral = 0.0
            prev_error = 0.0

        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        expected_su = tgt * elapsed / SESSION_MIN
        error = (expected_su - p.su) / max(tgt, 1.0)
        integral += error * POLL_INTERVAL
        integral = max(-5.0, min(5.0, integral))
        derivative = (error - prev_error) / POLL_INTERVAL
        output = 1.5 * error + 0.005 * integral + 2.0 * derivative
        prev_error = error
        cals.append(max(-1.0, min(1.0, -output)))
    return cals


def run_multi_burn(polls: list[Poll]) -> list[float]:
    """C6: Multi-burn-rate SRE approach."""
    cals: list[float] = []
    session_polls: list[Poll] = []

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        if elapsed < 5:
            cals.append(0.0)
            continue

        s_frac = p.sr / SESSION_MIN
        windows = [30.0, 90.0, elapsed]
        best_signal = 0.0

        for w in windows:
            if w > elapsed or w < POLL_INTERVAL:
                continue
            t_start = p.t - w
            su_at_start = 0.0
            for sp in session_polls:
                if sp.t <= t_start:
                    su_at_start = sp.su
            actual_usage = p.su - su_at_start
            expected_usage = tgt * (w / SESSION_MIN)
            if expected_usage < 1e-6:
                continue
            burn_rate = actual_usage / expected_usage
            burn_signal = tanh(1.5 * (burn_rate - 1.0))
            if abs(burn_signal) > abs(best_signal):
                best_signal = burn_signal

        cal = 0.7 * best_signal + 0.3 * (1 - s_frac) * (-dev)
        cals.append(max(-1.0, min(1.0, cal)))
    return cals


def run_pace(polls: list[Poll]) -> list[float]:
    """C5: Parameter-free adaptive pacing (PACE)."""
    cals: list[float] = []
    session_polls: list[Poll] = []
    lam = 1.0
    cum_grad_sq = 0.0

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
            lam = 1.0
            cum_grad_sq = 0.0
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        if elapsed < 5:
            cals.append(0.0)
            continue

        velocity = ema_velocity(session_polls)
        if velocity is None:
            velocity = p.su / max(elapsed, 0.1)
        velocity = max(velocity, 0.0)
        target_rate = (tgt - p.su) / max(p.sr, 0.1)
        target_rate = max(target_rate, 0.0)

        gradient = velocity - target_rate
        cum_grad_sq += gradient * gradient
        step = 1.0 / (1.0 + cum_grad_sq ** 0.5)
        lam = max(0.01, lam + step * gradient)
        cals.append(max(-1.0, min(1.0, lam - 1.0)))
    return cals


def run_gradient(polls: list[Poll]) -> list[float]:
    """C7: Gradient-based pacing with AdaGrad."""
    cals: list[float] = []
    session_polls: list[Poll] = []
    m = 1.0
    cum_grad_sq = 0.0

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
            m = 1.0
            cum_grad_sq = 0.0
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        if elapsed < 5:
            cals.append(0.0)
            continue

        velocity = ema_velocity(session_polls)
        if velocity is None:
            velocity = p.su / max(elapsed, 0.1)
        velocity = max(velocity, 0.0)
        target_rate = (tgt - p.su) / max(p.sr, 0.1)
        target_rate = max(target_rate, 0.0)

        gradient = velocity - target_rate
        cum_grad_sq += gradient * gradient
        eta = 0.5 / (1.0 + cum_grad_sq ** 0.5)
        m = max(0.01, m + eta * gradient)
        cals.append(max(-1.0, min(1.0, tanh(2 * (m - 1.0)))))
    return cals


def run_cascade(polls: list[Poll]) -> list[float]:
    """F1: Cascade controller with outer weekly PI + inner rate loop."""
    cals: list[float] = []
    session_polls: list[Poll] = []
    outer_integral = 0.0
    dynamic_target = 100.0
    poll_counter = 0

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
            poll_counter = 0
        session_polls.append(p)
        poll_counter += 1

        # Outer loop: every 6 polls (~30 min)
        if poll_counter % 6 == 0:
            we = weekly_expected(p)
            error = (we - p.wu) / 100.0
            outer_integral += error
            outer_integral = max(-5.0, min(5.0, outer_integral))
            dynamic_target = max(10.0, min(100.0,
                100.0 * (1.0 + 0.8 * error + 0.003 * outer_integral)))

        # Inner loop: rate comparison using dynamic_target
        if p.sr <= 0:
            cals.append(0.0)
            continue

        tau = max(p.sr, 0.1)
        optimal = min(max((dynamic_target - p.su) / tau, 0),
                      max((100 - p.su) / tau, 0))

        velocity = ema_velocity(session_polls)
        elapsed = SESSION_MIN - p.sr
        if velocity is None:
            if elapsed < 5:
                cals.append(0.0)
                continue
            velocity = p.su / max(elapsed, 0.1)

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            cals.append(1.0 if vel > 1e-6 else 0.0)
        else:
            cals.append(max(-1.0, min(1.0, (vel - optimal) / optimal)))
    return cals


def run_triple_blend(polls: list[Poll]) -> list[float]:
    """G2: Triple blend of positional, velocity, and budget signals."""
    cals: list[float] = []
    session_polls: list[Poll] = []

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue

        elapsed = SESSION_MIN - p.sr
        s_frac = p.sr / SESSION_MIN

        # Signal 1: Positional
        expected_su = tgt * (elapsed / SESSION_MIN)
        positional = max(-1.0, min(1.0, (p.su - expected_su) / max(tgt, 1.0)))

        # Signal 2: Velocity
        velocity = ema_velocity(session_polls)
        optimal = (tgt - p.su) / max(p.sr, 0.1)
        if velocity is not None and optimal > 1e-6:
            velocity_sig = max(-1.0, min(1.0, (velocity - optimal) / optimal))
        else:
            velocity_sig = 0.0

        # Signal 3: Budget
        budget_sig = -dev

        # Time-varying weights
        if elapsed < 30:
            w = (0.2, 0.6, 0.2)
        elif s_frac > 0.5:
            w = (0.3, 0.5, 0.2)
        else:
            w = (0.2, 0.2, 0.6)

        raw = w[0] * positional + w[1] * velocity_sig + w[2] * budget_sig
        cals.append(max(-1.0, min(1.0, raw)))
    return cals


def run_pb_pipeline(polls: list[Poll]) -> list[float]:
    """Path B + G1: three-layer signal conditioning (dead-zone, hysteresis, smoothing)."""
    cals: list[float] = []
    zone = "ok"
    prev_output = 0.0

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            zone = "ok"
            prev_output = 0.0

        # Raw Path B signal
        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue
        elapsed = SESSION_MIN - p.sr
        if elapsed < 5:
            cals.append(0.0)
            continue
        expected_su = tgt * (elapsed / SESSION_MIN)
        session_err = (p.su - expected_su) / max(tgt, 1.0)
        s_frac = p.sr / SESSION_MIN
        raw = max(-1.0, min(1.0, s_frac * session_err + (1 - s_frac) * (-dev)))

        # Dead-zone
        if abs(raw) < 0.08:
            dz = 0.0
        else:
            sign = 1.0 if raw > 0 else -1.0
            dz = sign * (abs(raw) - 0.08) / 0.92

        # Hysteresis
        if zone == "ok":
            if dz > 0.15:
                zone = "fast"
                hz = dz
            elif dz < -0.15:
                zone = "slow"
                hz = dz
            else:
                hz = 0.0
        elif zone == "fast":
            if dz < 0.05:
                zone = "ok"
                hz = 0.0
            else:
                hz = dz
        else:  # slow
            if dz > -0.05:
                zone = "ok"
                hz = 0.0
            else:
                hz = dz

        # Output smoothing
        output = 0.15 * hz + 0.85 * prev_output
        prev_output = output
        cals.append(max(-1.0, min(1.0, output)))
    return cals


def run_soft_throttle(polls: list[Poll]) -> list[float]:
    """C4: LinkedIn-style soft throttle with tanh mapping."""
    cals: list[float] = []
    session_polls: list[Poll] = []

    for i, p in enumerate(polls):
        prev = polls[i - 1] if i > 0 else None
        if detect_boundary(p, prev):
            session_polls = []
        session_polls.append(p)

        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr <= 0:
            cals.append(0.0)
            continue

        tau = max(p.sr, 0.1)
        optimal = min(max((tgt - p.su) / tau, 0), max((100 - p.su) / tau, 0))

        velocity = ema_velocity(session_polls)
        elapsed = SESSION_MIN - p.sr
        if velocity is None:
            if elapsed < 5:
                cals.append(0.0)
                continue
            velocity = p.su / max(elapsed, 0.1)

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            cals.append(1.0 if vel > 1e-6 else 0.0)
        else:
            cals.append(max(-1.0, min(1.0, tanh(1.5 * (vel / optimal - 1.0)))))
    return cals


BATCH_ALGORITHMS = {
    "Current": run_current,
    "Path A": run_path_a,
    "Path B": run_path_b,
    "Holt": run_holt,
    "AlphaBeta": run_alpha_beta,
    "PID": run_pid,
    "MultiBurn": run_multi_burn,
    "PACE": run_pace,
    "Gradient": run_gradient,
    "Cascade": run_cascade,
    "TriBlend": run_triple_blend,
    "PB+Pipe": run_pb_pipeline,
    "SoftThrot": run_soft_throttle,
}


# ── Open-loop simulator ───────────────────────────────────────────────


def simulate_week(profile_fn, seed: int) -> list[Poll]:
    rng = np.random.default_rng(seed)
    polls: list[Poll] = []

    wu = 0.0
    su = 0.0
    sr = 0.0
    in_session = False
    session_num = 0
    last_session_end = -9999.0

    for tick in range(int(WEEK_MIN / POLL_INTERVAL)):
        t = tick * POLL_INTERVAL
        wr = WEEK_MIN - t
        day = int(t / 1440)
        hour = (t % 1440) / 60
        is_active = ACTIVE_START <= hour < ACTIVE_END

        if in_session:
            sr = max(0.0, sr - POLL_INTERVAL)
            if sr <= 0:
                in_session = False
                su = 0.0
                last_session_end = t

        if is_active and not in_session:
            gap = t - last_session_end
            needed_gap = 10 + rng.exponential(20) if session_num > 0 else 0
            if gap >= needed_gap:
                in_session = True
                session_num += 1
                su = 0.0
                sr = SESSION_MIN

        if in_session and is_active:
            elapsed = SESSION_MIN - sr
            delta = profile_fn(rng, elapsed, session_num, day, hour)
            delta = max(0.0, min(delta, 100.0 - su))
            su += delta
            wu = min(100.0, wu + delta * EXCHANGE_RATE)

        if in_session:
            polls.append(Poll(t=t, su=su, sr=sr, wu=wu, wr=wr))

    return polls


# ── Open-loop analysis ─────────────────────────────────────────────────


@dataclass(slots=True)
class Stats:
    mean_abs: float
    std: float
    saturation_pct: float  # |cal| > 0.9
    p95_abs: float
    flip_flops_per_hr: float
    early_abs: float  # first 30 min of session
    mid_abs: float
    late_abs: float  # last 30 min of session
    boundary_ratio: float  # (early + late) / (2 * mid)
    wrong_dir_pct: float
    mid_max_jump: float  # max |Δcal| between consecutive mid-session polls
    mid_spike_rate: float  # spikes/hr where |Δcal| > 0.4 in mid-session
    mid_p95: float  # P95 of |cal| in mid-session


@dataclass(slots=True)
class EdgeCoverage:
    tail_danger: int
    startup_spike: int
    weekly_extreme: int
    total_polls: int


def compute_stats(polls: list[Poll], cals_list: list[float]) -> Stats | None:
    if len(cals_list) < 10:
        return None

    c = np.array(cals_list)

    mean_abs = float(np.mean(np.abs(c)))
    std = float(np.std(c))
    saturation = float(np.mean(np.abs(c) > 0.9) * 100)
    p95 = float(np.percentile(np.abs(c), 95))

    # Flip-flops (sign changes ignoring near-zero)
    nz = c[np.abs(c) > 0.05]
    if len(nz) > 1:
        signs = np.sign(nz)
        changes = int(np.sum(signs[1:] != signs[:-1]))
        hrs = (polls[-1].t - polls[0].t) / 60
        ff = changes / max(hrs, 1)
    else:
        ff = 0.0

    # Phase analysis
    early, mid_vals, late = [], [], []
    mid_jumps: list[float] = []
    prev_mid_cal: float | None = None

    for j, p in enumerate(polls):
        elapsed = SESSION_MIN - p.sr
        ac = abs(c[j])
        if elapsed <= 30:
            early.append(ac)
            prev_mid_cal = None
        elif p.sr <= 30:
            late.append(ac)
            prev_mid_cal = None
        else:
            mid_vals.append(ac)
            if prev_mid_cal is not None:
                mid_jumps.append(abs(c[j] - prev_mid_cal))
            prev_mid_cal = c[j]

    ea = float(np.mean(early)) if early else 0.0
    ma = float(np.mean(mid_vals)) if mid_vals else 0.0
    la = float(np.mean(late)) if late else 0.0
    br = ((ea + la) / (2 * ma)) if ma > 0.01 else 0.0

    # Mid-session spike metrics
    mmj = float(max(mid_jumps)) if mid_jumps else 0.0
    mid_spike_count = sum(1 for j in mid_jumps if j > 0.4)
    mid_hrs = len(mid_vals) * POLL_INTERVAL / 60
    msr = mid_spike_count / max(mid_hrs, 1.0)
    mp95 = float(np.percentile(mid_vals, 95)) if len(mid_vals) >= 5 else 0.0

    # Wrong direction
    wrong = 0
    total_nz = 0
    for j, p in enumerate(polls):
        if abs(c[j]) < 0.05:
            continue
        total_nz += 1
        exp = weekly_expected(p)
        err = p.wu - exp
        if err > 1 and c[j] < -0.1:
            wrong += 1
        elif err < -1 and c[j] > 0.1:
            wrong += 1

    wd = (wrong / total_nz * 100) if total_nz > 0 else 0.0

    return Stats(
        mean_abs=mean_abs, std=std, saturation_pct=saturation, p95_abs=p95,
        flip_flops_per_hr=ff, early_abs=ea, mid_abs=ma, late_abs=la,
        boundary_ratio=br, wrong_dir_pct=wd,
        mid_max_jump=mmj, mid_spike_rate=msr, mid_p95=mp95,
    )


def compute_edge_coverage(
    polls: list[Poll], cals: list[float], algo_name: str,
) -> EdgeCoverage:
    tail = startup = weekly_ext = 0
    for j, p in enumerate(polls):
        elapsed = SESSION_MIN - p.sr
        dev = weekly_deviation(p)
        tgt = session_target(dev)
        if p.sr < 30 and (tgt - p.su) > 20:
            tail += 1
        if elapsed < 30 and abs(cals[j]) > 0.7:
            startup += 1
        if abs(dev) > 0.8:
            weekly_ext += 1
    return EdgeCoverage(tail, startup, weekly_ext, len(polls))


def aggregate(stats_list: list[Stats]) -> Stats | None:
    if not stats_list:
        return None
    fields = [f.name for f in stats_list[0].__dataclass_fields__.values()]
    vals = {f: float(np.mean([getattr(s, f) for s in stats_list])) for f in fields}
    return Stats(**vals)


# ── Open-loop output ───────────────────────────────────────────────────

OPEN_METRICS = [
    ("Mean |cal|", "mean_abs", ".3f"),
    ("Std dev", "std", ".3f"),
    ("Saturation %", "saturation_pct", ".1f"),
    ("P95 |cal|", "p95_abs", ".3f"),
    ("Flip-flops/hr", "flip_flops_per_hr", ".2f"),
    ("Early session |cal|", "early_abs", ".3f"),
    ("Mid session |cal|", "mid_abs", ".3f"),
    ("Late session |cal|", "late_abs", ".3f"),
    ("Boundary ratio", "boundary_ratio", ".2f"),
    ("Wrong direction %", "wrong_dir_pct", ".1f"),
    ("Mid max jump", "mid_max_jump", ".3f"),
    ("Mid spikes/hr", "mid_spike_rate", ".2f"),
    ("Mid P95 |cal|", "mid_p95", ".3f"),
]


def _esc(s: str) -> str:
    return s.replace("|", "\\|")


def print_table(label: str, results: dict[str, Stats | None], metrics=OPEN_METRICS):
    algos = [a for a in results if results[a] is not None]
    if not algos:
        return

    print(f"\n### {label}\n")
    print("| Metric | " + " | ".join(algos) + " |")
    print("|--------|" + "-------:|" * len(algos))

    for name, attr, fmt in metrics:
        vals = [getattr(results[a], attr) for a in algos]
        best = min(vals)
        cells = []
        for v in vals:
            s = f"{v:{fmt}}"
            cells.append(f"**{s}**" if v == best and vals.count(best) == 1 else s)
        print(f"| {_esc(name)} | " + " | ".join(cells) + " |")

    print()


def print_coverage(coverage: dict[str, dict[str, EdgeCoverage]]):
    algos = list(next(iter(coverage.values())).keys())

    print("\n### Edge-Case Coverage\n")
    print("_Total events across all runs_\n")

    for condition, attr in [
        ("Tail Danger Zone", "tail_danger"),
        ("Startup Spike", "startup_spike"),
        ("Weekly Extreme", "weekly_extreme"),
    ]:
        print(f"\n#### {condition}\n")
        print("| Profile | " + " | ".join(algos) + " |")
        print("|---------|" + "-------:|" * len(algos))
        for pname in coverage:
            cells = []
            for a in algos:
                ec = coverage[pname][a]
                n = getattr(ec, attr)
                pct = n / ec.total_polls * 100 if ec.total_polls > 0 else 0
                cells.append(f"{n} ({pct:.0f}%)")
            print(f"| {pname} | " + " | ".join(cells) + " |")
        print()


def print_open_verdict(overall: dict[str, Stats | None]):
    algos = [a for a in overall if overall[a] is not None]
    if not algos:
        return

    print("\n### Open-Loop Verdict\n")

    for attr, description in [
        ("saturation_pct", "Saturation (pegged at extremes)"),
        ("boundary_ratio", "Boundary instability (1.0 = uniform)"),
        ("flip_flops_per_hr", "Signal noise (flip-flops)"),
        ("wrong_dir_pct", "Giving wrong advice"),
        ("early_abs", "Early-session reactivity"),
        ("late_abs", "Late-session explosion"),
        ("mid_spike_rate", "Mid-session spikes"),
    ]:
        vals = {a: getattr(overall[a], attr) for a in algos}
        best_algo = min(vals, key=vals.get)
        worst_algo = max(vals, key=vals.get)
        improvement = (
            (vals[worst_algo] - vals[best_algo]) / vals[worst_algo] * 100
            if vals[worst_algo] > 0
            else 0
        )
        print(f"**{description}:**\n")
        for a in algos:
            tag = " ← best" if a == best_algo else ""
            print(f"- {a}: {vals[a]:.3f}{tag}")
        if improvement > 5:
            print(f"- → **{best_algo}** is {improvement:.0f}% better than {worst_algo}")
        print()


# ════════════════════════════════════════════════════════════════════════
#  PART 2: CLOSED-LOOP (BACKTESTING)
# ════════════════════════════════════════════════════════════════════════

# ── Step-based algorithms ──────────────────────────────────────────────


class CurrentStep:
    def __init__(self):
        self.session_polls: list[Poll] = []
        self.prev: Poll | None = None
        self._ema: float | None = None

    def reset(self):
        self.session_polls.clear()
        self.prev = None
        self._ema = None

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self._ema = None
        self.session_polls.append(poll)

        # Incremental EMA
        if len(self.session_polls) >= 2:
            pp = self.session_polls[-2]
            dt = poll.t - pp.t
            if 0 < dt <= GAP_THRESHOLD:
                instant = (poll.su - pp.su) / dt
                self._ema = (
                    instant if self._ema is None
                    else EMA_ALPHA * instant + (1 - EMA_ALPHA) * self._ema
                )

        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        tau = max(poll.sr, 0.1)
        optimal = min(max((tgt - poll.su) / tau, 0), max((100 - poll.su) / tau, 0))

        velocity = self._ema
        elapsed = SESSION_MIN - poll.sr
        if velocity is None:
            if elapsed < 5:
                return 0.0
            velocity = poll.su / max(elapsed, 0.1)

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            return 1.0 if vel > 1e-6 else 0.0
        return max(-1.0, min(1.0, (vel - optimal) / optimal))


class PathAStep:
    def __init__(self):
        self.session_polls: list[Poll] = []
        self.prev: Poll | None = None
        self._ema: float | None = None

    def reset(self):
        self.session_polls.clear()
        self.prev = None
        self._ema = None

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self._ema = None
        self.session_polls.append(poll)

        if len(self.session_polls) >= 2:
            pp = self.session_polls[-2]
            dt = poll.t - pp.t
            if 0 < dt <= GAP_THRESHOLD:
                instant = (poll.su - pp.su) / dt
                self._ema = (
                    instant if self._ema is None
                    else EMA_ALPHA * instant + (1 - EMA_ALPHA) * self._ema
                )

        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        elapsed = SESSION_MIN - poll.sr
        tau = max(poll.sr, 0.1)
        optimal = min(max((tgt - poll.su) / tau, 0), max((100 - poll.su) / tau, 0))

        raw_vel = self._ema
        if raw_vel is None:
            if elapsed < 5:
                return 0.0
            velocity = poll.su / max(elapsed, 0.1)
        else:
            avg_vel = poll.su / max(elapsed, 0.1)
            frac = min(elapsed / 60.0, 1.0)
            velocity = frac * raw_vel + (1 - frac) * avg_vel

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            rate_cal = 1.0 if vel > 1e-6 else 0.0
        else:
            rate_cal = max(-1.0, min(1.0, (vel - optimal) / optimal))

        s_frac = poll.sr / SESSION_MIN
        weekly_cal = -dev
        return max(-1.0, min(1.0, s_frac * rate_cal + (1 - s_frac) * weekly_cal))


class PathBStep:
    def reset(self):
        pass

    def step(self, poll: Poll) -> float:
        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0
        elapsed = SESSION_MIN - poll.sr
        if elapsed < 5:
            return 0.0
        expected_su = tgt * (elapsed / SESSION_MIN)
        session_err = (poll.su - expected_su) / max(tgt, 1.0)
        s_frac = poll.sr / SESSION_MIN
        weekly_signal = -dev
        return max(-1.0, min(1.0, s_frac * session_err + (1 - s_frac) * weekly_signal))


class NoFeedbackStep:
    """Baseline: always returns 0 (no pacing guidance)."""
    def reset(self):
        pass

    def step(self, _poll: Poll) -> float:
        return 0.0


class HoltStep:
    """A2: Holt's double exponential smoothing."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []
        self.s: float | None = None
        self.b: float = 0.0

    def reset(self):
        self.prev = None
        self.session_polls.clear()
        self.s = None
        self.b = 0.0

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self.s = None
            self.b = 0.0
        self.session_polls.append(poll)

        if len(self.session_polls) >= 2:
            pp = self.session_polls[-2]
            dt = poll.t - pp.t
            if 0 < dt <= GAP_THRESHOLD:
                iv = (poll.su - pp.su) / dt
                if self.s is None:
                    self.s = iv
                    self.b = 0.0
                else:
                    s_new = 0.3 * iv + 0.7 * (self.s + self.b)
                    self.b = 0.1 * (s_new - self.s) + 0.9 * self.b
                    self.s = s_new

        self.prev = poll
        return _rate_calibrator(poll, self.s)


class AlphaBetaStep:
    """A3: Alpha-beta filter."""
    def __init__(self):
        self.prev: Poll | None = None
        self.x: float = 0.0
        self.v: float | None = None
        self.last_t: float | None = None

    def reset(self):
        self.prev = None
        self.x = 0.0
        self.v = None
        self.last_t = None

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.x = poll.su
            self.v = None
            self.last_t = poll.t
            self.prev = poll
            return _rate_calibrator(poll, self.v)

        dt = poll.t - self.last_t if self.last_t is not None else 0.0
        if 0 < dt <= GAP_THRESHOLD and self.v is not None:
            x_pred = self.x + self.v * dt
            residual = poll.su - x_pred
            self.x = x_pred + 0.2 * residual
            self.v = self.v + (0.1 / dt) * residual
        elif 0 < dt <= GAP_THRESHOLD and self.v is None:
            x_pred = self.x
            residual = poll.su - x_pred
            self.x = x_pred + 0.2 * residual
            self.v = (0.1 / dt) * residual
        else:
            self.x = poll.su
            self.v = None

        self.last_t = poll.t
        self.prev = poll
        return _rate_calibrator(poll, self.v)


class PIDStep:
    """C2: Classical PID controller."""
    def __init__(self):
        self.prev: Poll | None = None
        self.integral: float = 0.0
        self.prev_error: float = 0.0

    def reset(self):
        self.prev = None
        self.integral = 0.0
        self.prev_error = 0.0

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.integral = 0.0
            self.prev_error = 0.0
        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        elapsed = SESSION_MIN - poll.sr
        expected_su = tgt * elapsed / SESSION_MIN
        error = (expected_su - poll.su) / max(tgt, 1.0)
        self.integral += error * POLL_INTERVAL
        self.integral = max(-5.0, min(5.0, self.integral))
        derivative = (error - self.prev_error) / POLL_INTERVAL
        output = 1.5 * error + 0.005 * self.integral + 2.0 * derivative
        self.prev_error = error
        return max(-1.0, min(1.0, -output))


class MultiBurnStep:
    """C6: Multi-burn-rate SRE approach."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []

    def reset(self):
        self.prev = None
        self.session_polls.clear()

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
        self.session_polls.append(poll)
        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        elapsed = SESSION_MIN - poll.sr
        if elapsed < 5:
            return 0.0

        s_frac = poll.sr / SESSION_MIN
        windows = [30.0, 90.0, elapsed]
        best_signal = 0.0

        for w in windows:
            if w > elapsed or w < POLL_INTERVAL:
                continue
            t_start = poll.t - w
            su_at_start = 0.0
            for sp in self.session_polls:
                if sp.t <= t_start:
                    su_at_start = sp.su
            actual_usage = poll.su - su_at_start
            expected_usage = tgt * (w / SESSION_MIN)
            if expected_usage < 1e-6:
                continue
            burn_rate = actual_usage / expected_usage
            burn_signal = tanh(1.5 * (burn_rate - 1.0))
            if abs(burn_signal) > abs(best_signal):
                best_signal = burn_signal

        cal = 0.7 * best_signal + 0.3 * (1 - s_frac) * (-dev)
        return max(-1.0, min(1.0, cal))


class PACEStep:
    """C5: Parameter-free adaptive pacing."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []
        self.lam: float = 1.0
        self.cum_grad_sq: float = 0.0

    def reset(self):
        self.prev = None
        self.session_polls.clear()
        self.lam = 1.0
        self.cum_grad_sq = 0.0

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self.lam = 1.0
            self.cum_grad_sq = 0.0
        self.session_polls.append(poll)
        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        elapsed = SESSION_MIN - poll.sr
        if elapsed < 5:
            return 0.0

        velocity = ema_velocity(self.session_polls)
        if velocity is None:
            velocity = poll.su / max(elapsed, 0.1)
        velocity = max(velocity, 0.0)
        target_rate = max((tgt - poll.su) / max(poll.sr, 0.1), 0.0)

        gradient = velocity - target_rate
        self.cum_grad_sq += gradient * gradient
        step = 1.0 / (1.0 + self.cum_grad_sq ** 0.5)
        self.lam = max(0.01, self.lam + step * gradient)
        return max(-1.0, min(1.0, self.lam - 1.0))


class GradientStep:
    """C7: Gradient-based pacing with AdaGrad."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []
        self.m: float = 1.0
        self.cum_grad_sq: float = 0.0

    def reset(self):
        self.prev = None
        self.session_polls.clear()
        self.m = 1.0
        self.cum_grad_sq = 0.0

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self.m = 1.0
            self.cum_grad_sq = 0.0
        self.session_polls.append(poll)
        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        elapsed = SESSION_MIN - poll.sr
        if elapsed < 5:
            return 0.0

        velocity = ema_velocity(self.session_polls)
        if velocity is None:
            velocity = poll.su / max(elapsed, 0.1)
        velocity = max(velocity, 0.0)
        target_rate = max((tgt - poll.su) / max(poll.sr, 0.1), 0.0)

        gradient = velocity - target_rate
        self.cum_grad_sq += gradient * gradient
        eta = 0.5 / (1.0 + self.cum_grad_sq ** 0.5)
        self.m = max(0.01, self.m + eta * gradient)
        return max(-1.0, min(1.0, tanh(2 * (self.m - 1.0))))


class CascadeStep:
    """F1: Cascade controller with outer weekly PI + inner rate loop."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []
        self.outer_integral: float = 0.0
        self.dynamic_target: float = 100.0
        self.poll_counter: int = 0

    def reset(self):
        self.prev = None
        self.session_polls.clear()
        # outer_integral persists across sessions
        self.dynamic_target = 100.0
        self.poll_counter = 0

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self.poll_counter = 0
        self.session_polls.append(poll)
        self.poll_counter += 1
        self.prev = poll

        # Outer loop: every 6 polls
        if self.poll_counter % 6 == 0:
            we = weekly_expected(poll)
            error = (we - poll.wu) / 100.0
            self.outer_integral += error
            self.outer_integral = max(-5.0, min(5.0, self.outer_integral))
            self.dynamic_target = max(10.0, min(100.0,
                100.0 * (1.0 + 0.8 * error + 0.003 * self.outer_integral)))

        if poll.sr <= 0:
            return 0.0

        tau = max(poll.sr, 0.1)
        optimal = min(max((self.dynamic_target - poll.su) / tau, 0),
                      max((100 - poll.su) / tau, 0))

        velocity = ema_velocity(self.session_polls)
        elapsed = SESSION_MIN - poll.sr
        if velocity is None:
            if elapsed < 5:
                return 0.0
            velocity = poll.su / max(elapsed, 0.1)

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            return 1.0 if vel > 1e-6 else 0.0
        return max(-1.0, min(1.0, (vel - optimal) / optimal))


class TripleBlendStep:
    """G2: Triple blend of positional, velocity, and budget signals."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []

    def reset(self):
        self.prev = None
        self.session_polls.clear()

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
        self.session_polls.append(poll)
        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        elapsed = SESSION_MIN - poll.sr
        s_frac = poll.sr / SESSION_MIN

        expected_su = tgt * (elapsed / SESSION_MIN)
        positional = max(-1.0, min(1.0, (poll.su - expected_su) / max(tgt, 1.0)))

        velocity = ema_velocity(self.session_polls)
        optimal = (tgt - poll.su) / max(poll.sr, 0.1)
        if velocity is not None and optimal > 1e-6:
            velocity_sig = max(-1.0, min(1.0, (velocity - optimal) / optimal))
        else:
            velocity_sig = 0.0

        budget_sig = -dev

        if elapsed < 30:
            w = (0.2, 0.6, 0.2)
        elif s_frac > 0.5:
            w = (0.3, 0.5, 0.2)
        else:
            w = (0.2, 0.2, 0.6)

        raw = w[0] * positional + w[1] * velocity_sig + w[2] * budget_sig
        return max(-1.0, min(1.0, raw))


class PBPipelineStep:
    """Path B + G1: three-layer signal conditioning."""
    def __init__(self):
        self.prev: Poll | None = None
        self.zone: str = "ok"
        self.prev_output: float = 0.0

    def reset(self):
        self.prev = None
        self.zone = "ok"
        self.prev_output = 0.0

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.zone = "ok"
            self.prev_output = 0.0
        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0
        elapsed = SESSION_MIN - poll.sr
        if elapsed < 5:
            return 0.0
        expected_su = tgt * (elapsed / SESSION_MIN)
        session_err = (poll.su - expected_su) / max(tgt, 1.0)
        s_frac = poll.sr / SESSION_MIN
        raw = max(-1.0, min(1.0, s_frac * session_err + (1 - s_frac) * (-dev)))

        # Dead-zone
        if abs(raw) < 0.08:
            dz = 0.0
        else:
            sign = 1.0 if raw > 0 else -1.0
            dz = sign * (abs(raw) - 0.08) / 0.92

        # Hysteresis
        if self.zone == "ok":
            if dz > 0.15:
                self.zone = "fast"
                hz = dz
            elif dz < -0.15:
                self.zone = "slow"
                hz = dz
            else:
                hz = 0.0
        elif self.zone == "fast":
            if dz < 0.05:
                self.zone = "ok"
                hz = 0.0
            else:
                hz = dz
        else:  # slow
            if dz > -0.05:
                self.zone = "ok"
                hz = 0.0
            else:
                hz = dz

        output = 0.15 * hz + 0.85 * self.prev_output
        self.prev_output = output
        return max(-1.0, min(1.0, output))


class SoftThrottleStep:
    """C4: LinkedIn-style soft throttle with tanh mapping."""
    def __init__(self):
        self.prev: Poll | None = None
        self.session_polls: list[Poll] = []
        self._ema: float | None = None

    def reset(self):
        self.prev = None
        self.session_polls.clear()
        self._ema = None

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self.session_polls.clear()
            self._ema = None
        self.session_polls.append(poll)

        if len(self.session_polls) >= 2:
            pp = self.session_polls[-2]
            dt = poll.t - pp.t
            if 0 < dt <= GAP_THRESHOLD:
                instant = (poll.su - pp.su) / dt
                self._ema = (
                    instant if self._ema is None
                    else EMA_ALPHA * instant + (1 - EMA_ALPHA) * self._ema
                )

        self.prev = poll

        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0

        tau = max(poll.sr, 0.1)
        optimal = min(max((tgt - poll.su) / tau, 0), max((100 - poll.su) / tau, 0))

        velocity = self._ema
        elapsed = SESSION_MIN - poll.sr
        if velocity is None:
            if elapsed < 5:
                return 0.0
            velocity = poll.su / max(elapsed, 0.1)

        vel = max(velocity, 0.0)
        if optimal < 1e-6:
            return 1.0 if vel > 1e-6 else 0.0
        return max(-1.0, min(1.0, tanh(1.5 * (vel / optimal - 1.0))))


STEP_ALGORITHMS: dict[str, type] = {
    "No Feedback": NoFeedbackStep,
    "Current": CurrentStep,
    "Path A": PathAStep,
    "Path B": PathBStep,
    "Holt": HoltStep,
    "AlphaBeta": AlphaBetaStep,
    "PID": PIDStep,
    "MultiBurn": MultiBurnStep,
    "PACE": PACEStep,
    "Gradient": GradientStep,
    "Cascade": CascadeStep,
    "TriBlend": TripleBlendStep,
    "PB+Pipe": PBPipelineStep,
    "SoftThrot": SoftThrottleStep,
}


# ── Compliance profiles ────────────────────────────────────────────────

COMPLIANCE_PROFILES = {
    "Attentive": {"compliance": 0.6, "delay": 1, "noise_std": 0.08, "miss_prob": 0.20, "dead_zone": 0.35},
    "Casual": {"compliance": 0.35, "delay": 3, "noise_std": 0.15, "miss_prob": 0.40, "dead_zone": 0.50},
    "Distracted": {"compliance": 0.15, "delay": 6, "noise_std": 0.25, "miss_prob": 0.60, "dead_zone": 0.60},
}


# ── Closed-loop simulator ─────────────────────────────────────────────


def simulate_week_closed_loop(
    profile_fn, algo, seed: int,
    compliance: float, delay: int, noise_std: float,
    miss_prob: float = 0.0, dead_zone: float = 0.0,
) -> tuple[list[Poll], list[float]]:
    rng = np.random.default_rng(seed)
    algo.reset()
    polls: list[Poll] = []
    cals: list[float] = []
    session_cals: list[float] = []  # per-session cal buffer for delay
    consec_sat = 0  # consecutive ticks user saw a saturated signal

    wu = su = sr = 0.0
    in_session = False
    session_num = 0
    last_session_end = -9999.0

    for tick in range(int(WEEK_MIN / POLL_INTERVAL)):
        t = tick * POLL_INTERVAL
        wr = WEEK_MIN - t
        day = int(t / 1440)
        hour = (t % 1440) / 60
        is_active = ACTIVE_START <= hour < ACTIVE_END

        if in_session:
            sr = max(0.0, sr - POLL_INTERVAL)
            if sr <= 0:
                in_session = False
                su = 0.0
                last_session_end = t

        if is_active and not in_session:
            gap = t - last_session_end
            needed_gap = 10 + rng.exponential(20) if session_num > 0 else 0
            if gap >= needed_gap:
                in_session = True
                session_num += 1
                su = 0.0
                sr = SESSION_MIN
                session_cals = []  # fresh buffer each session
                consec_sat = 0

        if in_session and is_active:
            elapsed = SESSION_MIN - sr
            base_delta = profile_fn(rng, elapsed, session_num, day, hour)

            # Feedback: use calibrator from `delay` ticks ago in this session
            idx = len(session_cals) - delay
            raw_cal = session_cals[idx] if idx >= 0 and delay > 0 else 0.0

            # 1. Missed signal — user didn't glance at the icon this tick
            looked = rng.random() >= miss_prob

            if looked:
                # 3. Alarm fatigue — saturated signal erodes trust
                if abs(raw_cal) > FATIGUE_SAT:
                    consec_sat += 1
                else:
                    consec_sat = max(0, consec_sat - 1)  # slow recovery

                # 2. Dead zone — weak signals don't trigger action
                effective_cal = raw_cal if abs(raw_cal) >= dead_zone else 0.0
            else:
                effective_cal = 0.0

            fatigue = max(FATIGUE_FLOOR, 1.0 - FATIGUE_RATE * consec_sat)
            noisy_compliance = max(0.0, compliance + rng.normal(0, noise_std)) * fatigue
            rate_mult = max(0.15, 1.0 - noisy_compliance * effective_cal * COMPLIANCE_GAIN)
            delta = base_delta * rate_mult

            delta = max(0.0, min(delta, 100.0 - su))
            su += delta
            wu = min(100.0, wu + delta * EXCHANGE_RATE)

        if in_session:
            poll = Poll(t=t, su=su, sr=sr, wu=wu, wr=wr)
            polls.append(poll)
            cal = algo.step(poll)
            cals.append(cal)
            session_cals.append(cal)

    return polls, cals


# ── Closed-loop analysis ──────────────────────────────────────────────


@dataclass(slots=True)
class CLRunStats:
    final_wu: float
    cal_mean_abs: float
    cal_smoothness: float  # mean |Δcal|
    saturation_pct: float
    mid_spike_rate: float


@dataclass(slots=True)
class CLAgg:
    mean_final_wu: float
    std_final_wu: float
    p10_final_wu: float
    cal_mean_abs: float
    cal_smoothness: float
    saturation_pct: float
    mid_spike_rate: float


def compute_cl_stats(polls: list[Poll], cals: list[float]) -> CLRunStats | None:
    if len(polls) < 10:
        return None

    c = np.array(cals)
    final_wu = polls[-1].wu
    cal_mean_abs = float(np.mean(np.abs(c)))
    smoothness = float(np.mean(np.abs(np.diff(c)))) if len(c) > 1 else 0.0
    saturation = float(np.mean(np.abs(c) > 0.9) * 100)

    # Mid-session spike rate
    mid_jumps: list[float] = []
    mid_count = 0
    prev_mid_cal: float | None = None
    for j, p in enumerate(polls):
        elapsed = SESSION_MIN - p.sr
        if elapsed > 30 and p.sr > 30:
            mid_count += 1
            if prev_mid_cal is not None:
                mid_jumps.append(abs(c[j] - prev_mid_cal))
            prev_mid_cal = c[j]
        else:
            prev_mid_cal = None
    spike_count = sum(1 for j in mid_jumps if j > 0.4)
    mid_hrs = mid_count * POLL_INTERVAL / 60
    spike_rate = spike_count / max(mid_hrs, 1.0)

    return CLRunStats(
        final_wu=final_wu, cal_mean_abs=cal_mean_abs,
        cal_smoothness=smoothness, saturation_pct=saturation,
        mid_spike_rate=spike_rate,
    )


def aggregate_cl(stats_list: list[CLRunStats]) -> CLAgg | None:
    if not stats_list:
        return None
    fwu = [s.final_wu for s in stats_list]
    return CLAgg(
        mean_final_wu=float(np.mean(fwu)),
        std_final_wu=float(np.std(fwu)),
        p10_final_wu=float(np.percentile(fwu, 10)),
        cal_mean_abs=float(np.mean([s.cal_mean_abs for s in stats_list])),
        cal_smoothness=float(np.mean([s.cal_smoothness for s in stats_list])),
        saturation_pct=float(np.mean([s.saturation_pct for s in stats_list])),
        mid_spike_rate=float(np.mean([s.mid_spike_rate for s in stats_list])),
    )


# ── Closed-loop output ────────────────────────────────────────────────

# (name, attr, format, higher_is_better)
CLOSED_METRICS: list[tuple[str, str, str, bool]] = [
    ("Final WU (mean)", "mean_final_wu", ".1f", True),
    ("Final WU (P10)", "p10_final_wu", ".1f", True),
    ("Final WU (std)", "std_final_wu", ".1f", False),
    ("Cal mean |cal|", "cal_mean_abs", ".3f", False),
    ("Cal smoothness", "cal_smoothness", ".4f", False),
    ("Saturation %", "saturation_pct", ".1f", False),
    ("Mid spikes/hr", "mid_spike_rate", ".2f", False),
]


def print_cl_table(label: str, results: dict[str, CLAgg | None]):
    algos = [a for a in results if results[a] is not None]
    if not algos:
        return

    print(f"\n### {label}\n")
    print("| Metric | " + " | ".join(algos) + " |")
    print("|--------|" + "-------:|" * len(algos))

    for name, attr, fmt, higher_better in CLOSED_METRICS:
        vals = [getattr(results[a], attr) for a in algos]
        best = max(vals) if higher_better else min(vals)
        cells = []
        for v in vals:
            s = f"{v:{fmt}}"
            cells.append(f"**{s}**" if v == best and vals.count(best) == 1 else s)
        print(f"| {_esc(name)} | " + " | ".join(cells) + " |")

    print(f"\n_Higher Final WU = better; lower everything else = better_\n")


def print_cl_verdict(overall: dict[str, CLAgg | None]):
    algos = [a for a in overall if overall[a] is not None]
    if not algos:
        return

    baseline = overall.get("No Feedback")

    print("\n### Closed-Loop Verdict\n")

    if baseline:
        print("**Utilization improvement over baseline (No Feedback):**\n")
        print("| Algorithm | Final WU | Delta | Improvement |")
        print("|-----------|----------|-------|-------------|")
        for a in algos:
            if a == "No Feedback":
                continue
            agg = overall[a]
            if agg is None:
                continue
            delta = agg.mean_final_wu - baseline.mean_final_wu
            pct = delta / baseline.mean_final_wu * 100 if baseline.mean_final_wu > 0 else 0
            print(f"| {a} | {agg.mean_final_wu:.1f}% | +{delta:.1f}pp | +{pct:.0f}% |")
        print()

    print("**Best algorithm per metric:**\n")
    print("| Metric | Best | Value |")
    print("|--------|------|-------|")
    for name, attr, fmt, higher_better in CLOSED_METRICS:
        vals = {a: getattr(overall[a], attr) for a in algos if overall[a] is not None}
        best_algo = (max if higher_better else min)(vals, key=vals.get)
        print(f"| {_esc(name)} | **{best_algo}** | {vals[best_algo]:{fmt}} |")
    print()


# ════════════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════════════


def _ol_worker(pname_seed):
    """Open-loop worker: simulate one (profile, seed), run all algos."""
    pname, seed = pname_seed
    pfn = PROFILES[pname]
    polls = simulate_week(pfn, seed)
    if len(polls) < 20:
        return pname, None
    algo_results = {}
    for aname, afn in BATCH_ALGORITHMS.items():
        cals = afn(polls)
        st = compute_stats(polls, cals)
        ec = compute_edge_coverage(polls, cals, aname)
        algo_results[aname] = (st, ec)
    return pname, algo_results


def run_open_loop():
    n_profiles = len(PROFILES)
    n_sims = n_profiles * N_OPEN_RUNS

    print("## Part 1: Open-Loop Signal Quality\n")
    print(f"{n_profiles} profiles x {N_OPEN_RUNS} seeds x {len(BATCH_ALGORITHMS)} algorithms"
          f" = {n_sims} simulations ({N_WORKERS} workers)\n")

    t0 = time.monotonic()
    per_profile_algo: dict[str, dict[str, list[Stats]]] = {
        pname: {a: [] for a in BATCH_ALGORITHMS} for pname in PROFILES
    }
    per_profile_coverage: dict[str, dict[str, EdgeCoverage]] = {
        pname: {a: EdgeCoverage(0, 0, 0, 0) for a in BATCH_ALGORITHMS}
        for pname in PROFILES
    }

    tasks = [(pname, seed) for pname in PROFILES for seed in range(N_OPEN_RUNS)]
    done = 0

    with _MP_CTX.Pool(N_WORKERS) as pool:
        for pname, algo_results in pool.imap_unordered(_ol_worker, tasks, chunksize=50):
            done += 1
            if done % 200 == 0 or done == n_sims:
                elapsed = time.monotonic() - t0
                rate = done / elapsed if elapsed > 0 else 0
                eta = (n_sims - done) / rate if rate > 0 else 0
                sys.stderr.write(
                    f"\r  OL [{done}/{n_sims}] "
                    f"{elapsed:.0f}s elapsed, ~{eta:.0f}s remaining"
                )
                sys.stderr.flush()

            if algo_results is None:
                continue
            for aname, (st, ec) in algo_results.items():
                if st:
                    per_profile_algo[pname][aname].append(st)
                cc = per_profile_coverage[pname][aname]
                cc.tail_danger += ec.tail_danger
                cc.startup_spike += ec.startup_spike
                cc.weekly_extreme += ec.weekly_extreme
                cc.total_polls += ec.total_polls

    sys.stderr.write("\r" + " " * 72 + "\r")
    sys.stderr.flush()
    wall = time.monotonic() - t0
    print(f"_Completed in {wall:.1f}s ({n_sims / wall:.0f} sims/s)_\n")

    all_results = {
        pname: {a: aggregate(sl) for a, sl in per_profile_algo[pname].items()}
        for pname in PROFILES
    }

    for pname, results in all_results.items():
        print_table(f"{pname}  ({N_OPEN_RUNS} runs)", results)

    print_coverage(per_profile_coverage)

    overall: dict[str, Stats | None] = {}
    for aname in BATCH_ALGORITHMS:
        combined = [
            all_results[p][aname]
            for p in all_results
            if all_results[p][aname] is not None
        ]
        overall[aname] = aggregate(combined) if combined else None

    print_table(f"OVERALL  ({n_profiles} profiles × {N_OPEN_RUNS} runs)", overall)
    print_open_verdict(overall)


def _cl_worker(args):
    """Closed-loop worker: one (compliance, profile, seed), all algos."""
    cname, pname, seed = args
    pfn = PROFILES[pname]
    cp = COMPLIANCE_PROFILES[cname]
    algo_results = {}
    for aname, acls in STEP_ALGORITHMS.items():
        algo = acls()
        polls, cals = simulate_week_closed_loop(
            pfn, algo, seed,
            compliance=cp["compliance"],
            delay=cp["delay"],
            noise_std=cp["noise_std"],
            miss_prob=cp["miss_prob"],
            dead_zone=cp["dead_zone"],
        )
        st = compute_cl_stats(polls, cals)
        algo_results[aname] = st
    return cname, algo_results


def run_closed_loop():
    n_profiles = len(PROFILES)
    n_compliance = len(COMPLIANCE_PROFILES)
    n_algos = len(STEP_ALGORITHMS)
    n_tasks = n_profiles * n_compliance * N_CLOSED_RUNS
    n_total = n_tasks * n_algos

    print("\n---\n")
    print("## Part 2: Closed-Loop Backtesting\n")
    print(f"{n_profiles} profiles x {n_compliance} compliance x "
          f"{N_CLOSED_RUNS} seeds x {n_algos} algorithms = {n_total} sim-weeks"
          f" ({N_WORKERS} workers)\n")
    print(f"Compliance gain: {COMPLIANCE_GAIN} · "
          f"Fatigue: rate={FATIGUE_RATE}/tick, floor={FATIGUE_FLOOR}, "
          f"sat threshold={FATIGUE_SAT}\n")
    print("| Profile | Compliance | Delay (ticks) | Noise | Miss % | Dead zone |")
    print("|---------|-----------|--------------|-------|--------|-----------|")
    for cname, cp in COMPLIANCE_PROFILES.items():
        print(f"| {cname} | {cp['compliance']} | {cp['delay']} "
              f"| {cp['noise_std']} | {cp['miss_prob']:.0%} | {cp['dead_zone']} |")
    print()

    t0 = time.monotonic()
    results: dict[str, dict[str, list[CLRunStats]]] = {
        cname: {aname: [] for aname in STEP_ALGORITHMS}
        for cname in COMPLIANCE_PROFILES
    }

    tasks = [
        (cname, pname, seed)
        for cname in COMPLIANCE_PROFILES
        for pname in PROFILES
        for seed in range(N_CLOSED_RUNS)
    ]
    done = 0

    with _MP_CTX.Pool(N_WORKERS) as pool:
        for cname, algo_results in pool.imap_unordered(_cl_worker, tasks, chunksize=20):
            done += 1
            if done % 100 == 0 or done == len(tasks):
                elapsed = time.monotonic() - t0
                rate = done / elapsed if elapsed > 0 else 0
                eta = (len(tasks) - done) / rate if rate > 0 else 0
                sys.stderr.write(
                    f"\r  CL [{done}/{len(tasks)}] "
                    f"{elapsed:.0f}s elapsed, ~{eta:.0f}s remaining"
                )
                sys.stderr.flush()

            for aname, st in algo_results.items():
                if st:
                    results[cname][aname].append(st)

    sys.stderr.write("\r" + " " * 72 + "\r")
    sys.stderr.flush()
    wall = time.monotonic() - t0
    print(f"\n_Completed in {wall:.1f}s ({n_total / wall:.0f} sim-weeks/s)_\n")

    # Per-compliance tables
    all_aggs: dict[str, dict[str, CLAgg | None]] = {}
    for cname in COMPLIANCE_PROFILES:
        agg = {aname: aggregate_cl(sl) for aname, sl in results[cname].items()}
        all_aggs[cname] = agg
        cp = COMPLIANCE_PROFILES[cname]
        print_cl_table(
            f"{cname} (compliance={cp['compliance']}, "
            f"delay={cp['delay']}, noise={cp['noise_std']})",
            agg,
        )

    # Overall (across all compliance levels)
    overall: dict[str, CLAgg | None] = {}
    for aname in STEP_ALGORITHMS:
        combined = [
            st
            for cname in results
            for st in results[cname][aname]
        ]
        overall[aname] = aggregate_cl(combined) if combined else None

    print_cl_table(
        f"OVERALL  ({n_profiles} profiles × {n_compliance} compliance × {N_CLOSED_RUNS} runs)",
        overall,
    )
    print_cl_verdict(overall)


class _Tee:
    """Write to both stdout and a buffer."""
    def __init__(self, out, buf):
        self._out, self._buf = out, buf
    def write(self, s):
        self._out.write(s)
        self._buf.write(s)
    def flush(self):
        self._out.flush()
        self._buf.flush()


def main():
    now = datetime.now()
    timestamp = now.strftime("%Y-%m-%d_%H%M")
    script_dir = Path(__file__).resolve().parent
    outpath = script_dir / f"results_{timestamp}.md"

    buf = io.StringIO()
    orig_stdout = sys.stdout
    sys.stdout = _Tee(orig_stdout, buf)

    print(f"# Calibrator Algorithm Battle Royale\n")
    print(f"**{now.strftime('%Y-%m-%d %H:%M')}**\n")
    print("| Parameter | Value |")
    print("|-----------|-------|")
    print(f"| Exchange rate | {EXCHANGE_RATE} |")
    print(f"| Active hours | {ACTIVE_START:.0f}:00-{ACTIVE_END:.0f}:00 |")
    print(f"| Poll interval | {POLL_INTERVAL:.0f}m |")
    print(f"| Session | {SESSION_MIN:.0f}m |")
    print(f"| Week | {WEEK_MIN:.0f}m |")
    print(f"| Workers | {N_WORKERS} |")
    print()

    run_open_loop()
    run_closed_loop()

    sys.stdout = orig_stdout
    outpath.write_text(buf.getvalue())
    print(f"\nResults saved to {outpath}")


if __name__ == "__main__":
    main()
