from __future__ import annotations

import multiprocessing
import os
from dataclasses import dataclass

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
N_OPEN_RUNS = 50
N_CLOSED_RUNS = 30
COMPLIANCE_GAIN = 0.7  # max rate modulation from calibrator
FATIGUE_RATE = 0.003  # compliance decay per consecutive saturated tick
FATIGUE_FLOOR = 0.85  # minimum fatigue multiplier (15% max reduction)
FATIGUE_SAT = 0.9  # |cal| above this counts as saturated for fatigue
N_MW_WEEKS = 8
N_MW_RUNS = 20
N_WORKERS = min(os.cpu_count() or 4, 8)
MP_CTX = multiprocessing.get_context("fork")


# ── Data ────────────────────────────────────────────────────────────────


@dataclass(slots=True)
class Poll:
    t: float  # minutes from week start
    su: float  # session usage %
    sr: float  # session remaining min
    wu: float  # weekly usage %
    wr: float  # weekly remaining min
