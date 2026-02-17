from __future__ import annotations

from math import tanh

from constants import GAP_THRESHOLD, POLL_INTERVAL, SESSION_MIN, Poll
from helpers import (
    detect_boundary, ema_velocity, rate_calibrator, session_target,
    weekly_deviation, weekly_expected,
)


# ════════════════════════════════════════════════════════════════════════
#  PART 1: OPEN-LOOP — Batch algorithms
# ════════════════════════════════════════════════════════════════════════


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

        cals.append(rate_calibrator(p, s))
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
            cals.append(rate_calibrator(p, v))
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
        cals.append(rate_calibrator(p, v))
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
