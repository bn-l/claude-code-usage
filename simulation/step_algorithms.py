from __future__ import annotations

from math import tanh

from constants import EMA_ALPHA, GAP_THRESHOLD, POLL_INTERVAL, SESSION_MIN, Poll
from helpers import (
    detect_boundary, ema_velocity, rate_calibrator, session_target,
    weekly_deviation, weekly_expected,
)


# ════════════════════════════════════════════════════════════════════════
#  PART 2: CLOSED-LOOP — Step-based algorithms
# ════════════════════════════════════════════════════════════════════════


class NoFeedbackStep:
    """Baseline: always returns 0 (no pacing guidance)."""
    def reset(self):
        pass

    def step(self, _poll: Poll) -> float:
        return 0.0


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
        return rate_calibrator(poll, self.s)


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
            return rate_calibrator(poll, self.v)

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
        return rate_calibrator(poll, self.v)


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
