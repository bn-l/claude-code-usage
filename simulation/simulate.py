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
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np

from constants import (
    ACTIVE_END, ACTIVE_START, COMPLIANCE_GAIN, EXCHANGE_RATE, FATIGUE_FLOOR,
    FATIGUE_RATE, FATIGUE_SAT, MP_CTX, N_CLOSED_RUNS, N_OPEN_RUNS,
    N_WORKERS, POLL_INTERVAL, SESSION_MIN, WEEK_MIN, Poll,
)
from profiles import COMPLIANCE_PROFILES, PROFILES
from helpers import detect_boundary
from batch_algorithms import BATCH_ALGORITHMS
from step_algorithms import STEP_ALGORITHMS
from analysis import (
    CLRunStats, EdgeCoverage, Stats,
    aggregate, aggregate_cl, compute_cl_stats, compute_edge_coverage,
    compute_stats, print_cl_table, print_cl_verdict, print_coverage,
    print_open_verdict, print_table,
)


# ════════════════════════════════════════════════════════════════════════
#  OPEN-LOOP SIMULATOR
# ════════════════════════════════════════════════════════════════════════


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


# ════════════════════════════════════════════════════════════════════════
#  CLOSED-LOOP SIMULATOR
# ════════════════════════════════════════════════════════════════════════


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


# ════════════════════════════════════════════════════════════════════════
#  MULTIPROCESSING WORKERS
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


# ════════════════════════════════════════════════════════════════════════
#  RUN LOOPS
# ════════════════════════════════════════════════════════════════════════


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

    with MP_CTX.Pool(N_WORKERS) as pool:
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

    with MP_CTX.Pool(N_WORKERS) as pool:
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


# ════════════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════════════


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
