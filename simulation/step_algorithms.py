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


class AdaptiveStep:
    """Adaptive controller: learns user response function, produces minimum-amplitude signals."""

    PRIOR_GAIN = 0.30  # normalized: compliance * COMPLIANCE_GAIN
    PRIOR_DZ = 0.25
    GAIN_FLOOR = 0.01  # normalized floor
    GAIN_CAP = 1.5     # normalized cap (compliance * gain can't exceed ~0.7)
    WARMUP_N = 20
    ALPHA_GAIN = 0.08
    ALPHA_BL = 0.1
    ALPHA_VAR = 0.05
    MAX_DELTA_C = 0.2
    NOISE_FLOOR = 0.005
    DZ_STEP = 0.005
    DZ_MIN = 0.05
    DZ_MAX = 0.8
    DZ_WINDOW = 0.12
    SIGNAL_CAP = 0.85
    MAX_DELAY = 8
    DELAY_BUF_SIZE = 60

    def __init__(self):
        self._init_session()
        self._init_learned()

    def _init_session(self):
        self.session_polls: list[Poll] = []
        self.prev: Poll | None = None
        self._ema: float | None = None
        self.prev_signal: float = 0.0
        self.signal_history: list[float] = []

    def _init_learned(self):
        self.gain: float = self.PRIOR_GAIN
        self.dead_zone: float = self.PRIOR_DZ
        self.confidence: float = 0.0
        self.baseline_rate: float = 0.3
        self.gain_obs_count: int = 0
        self.gain_variance: float = 0.1
        self.estimated_delay: int = 1
        self._delay_buf: list[tuple[float, list[float]]] = []

    def reset(self):
        self._init_session()
        # learned params (gain, dead_zone, confidence, baseline_rate) persist

    def step(self, poll: Poll) -> float:
        if detect_boundary(poll, self.prev):
            self._init_session()
        self.session_polls.append(poll)

        if len(self.session_polls) >= 2:
            pp = self.session_polls[-2]
            dt = poll.t - pp.t
            if 0 < dt <= GAP_THRESHOLD:
                iv = (poll.su - pp.su) / dt
                self._ema = (
                    iv if self._ema is None
                    else EMA_ALPHA * iv + (1 - EMA_ALPHA) * self._ema
                )

        self.prev = poll
        self._learn(poll)

        error = self._pace_error(poll)
        signal = self._to_signal(error)
        self.signal_history.append(signal)
        self.prev_signal = signal
        return signal

    def _pace_error(self, poll: Poll) -> float:
        dev = weekly_deviation(poll)
        tgt = session_target(dev)
        if poll.sr <= 0:
            return 0.0
        elapsed = SESSION_MIN - poll.sr
        tau = max(poll.sr, 0.1)
        optimal = min(max((tgt - poll.su) / tau, 0), max((100 - poll.su) / tau, 0))
        vel = self._ema
        if vel is None:
            if elapsed < 5:
                return 0.0
            vel = poll.su / max(elapsed, 0.1)
        return max(vel, 0.0) - optimal

    def _to_signal(self, error: float) -> float:
        if abs(error) < self.NOISE_FLOOR:
            raw = 0.0
        else:
            eff_gain = (self.confidence * self.gain
                        + (1 - self.confidence) * self.PRIOR_GAIN)
            # gain is normalized (dimensionless), scale by baseline_rate for absolute units
            raw = error / max(self.baseline_rate * eff_gain, 0.001)
            # dead zone boost — if signaling, ensure we exceed perception threshold
            if 0 < abs(raw) < self.dead_zone * 1.1:
                raw = (1.0 if raw > 0 else -1.0) * self.dead_zone * 1.1

        delta = max(-self.MAX_DELTA_C, min(self.MAX_DELTA_C, raw - self.prev_signal))
        # hard cap below fatigue threshold (FATIGUE_SAT=0.9) to prevent fatigue cycle
        return max(-self.SIGNAL_CAP, min(self.SIGNAL_CAP, self.prev_signal + delta))

    def _learn(self, poll: Poll):
        if len(self.session_polls) < 3:
            return
        if SESSION_MIN - poll.sr < 5:
            return
        pp = self.session_polls[-2]
        dt = poll.t - pp.t
        if dt <= 0 or dt > GAP_THRESHOLD:
            return

        observed_rate = (poll.su - pp.su) / dt

        # need enough signal history to probe all candidate delays
        if len(self.signal_history) < self.MAX_DELAY:
            return

        # accumulate (rate, signals-at-each-lag) for delay estimation
        sigs = [self.signal_history[-d] for d in range(1, self.MAX_DELAY + 1)]
        self._delay_buf.append((observed_rate, sigs))
        if len(self._delay_buf) > self.DELAY_BUF_SIZE:
            self._delay_buf.pop(0)

        self._estimate_delay()

        past_signal = self.signal_history[-self.estimated_delay]

        # baseline update from low-signal periods
        if abs(past_signal) < self.dead_zone * 0.5:
            self.baseline_rate = (
                (1 - self.ALPHA_BL) * self.baseline_rate
                + self.ALPHA_BL * observed_rate
            )
            return

        # gain update from above-dead-zone signals
        if abs(past_signal) > self.dead_zone:
            response = observed_rate - self.baseline_rate
            # miss-aware: skip near-zero responses (likely missed, not low gain)
            if abs(response) < 0.01:
                return
            # normalized gain: divide response by baseline_rate for dimensionless estimate
            bl = max(abs(self.baseline_rate), 0.01)
            obs_gain = max(self.GAIN_FLOOR, min(self.GAIN_CAP, -response / (bl * past_signal)))

            self.gain = (1 - self.ALPHA_GAIN) * self.gain + self.ALPHA_GAIN * obs_gain
            self.gain = max(self.GAIN_FLOOR, self.gain)

            self.gain_obs_count += 1
            diff_sq = (obs_gain - self.gain) ** 2
            self.gain_variance = (
                (1 - self.ALPHA_VAR) * self.gain_variance + self.ALPHA_VAR * diff_sq
            )

            warmup = min(1.0, self.gain_obs_count / self.WARMUP_N)
            stability = 1.0 / (1.0 + self.gain_variance)
            self.confidence = warmup * stability

        # dead zone update from near-boundary signals
        if abs(abs(past_signal) - self.dead_zone) < self.DZ_WINDOW:
            response = observed_rate - self.baseline_rate
            responded = response * past_signal < 0 and abs(response) > 0.01
            if responded:
                self.dead_zone = max(self.DZ_MIN, self.dead_zone - self.DZ_STEP)
            else:
                self.dead_zone = min(self.DZ_MAX, self.dead_zone + self.DZ_STEP)

    def _estimate_delay(self):
        """Cross-correlate signal at lags 1..MAX_DELAY with rate response."""
        if len(self._delay_buf) < 20:
            return
        rates = [r for r, _ in self._delay_buf]
        mean_rate = sum(rates) / len(rates)

        best_lag = self.estimated_delay
        best_score = -float('inf')

        for d_idx in range(self.MAX_DELAY):
            score = 0.0
            n = 0
            for rate, sigs_at_lags in self._delay_buf:
                s = sigs_at_lags[d_idx]
                if abs(s) > 0.1:  # only count meaningful signals
                    score += -(rate - mean_rate) * s
                    n += 1
            if n >= 5:
                score /= n
                if score > best_score:
                    best_score = score
                    best_lag = d_idx + 1  # 1-indexed lag
        if best_score > 0:
            self.estimated_delay = best_lag


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
    "Adaptive": AdaptiveStep,
}
