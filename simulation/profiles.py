from __future__ import annotations

import numpy as np


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


# ── Compliance profiles ────────────────────────────────────────────────

COMPLIANCE_PROFILES = {
    "Attentive": {"compliance": 0.6, "delay": 1, "noise_std": 0.08, "miss_prob": 0.20, "dead_zone": 0.35},
    "Casual": {"compliance": 0.35, "delay": 3, "noise_std": 0.15, "miss_prob": 0.40, "dead_zone": 0.50},
    "Distracted": {"compliance": 0.15, "delay": 6, "noise_std": 0.25, "miss_prob": 0.60, "dead_zone": 0.60},
}
