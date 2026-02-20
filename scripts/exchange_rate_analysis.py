#!/usr/bin/env python3
"""Analyse exchange rate (weekly% / session%) from historical poll data.

Uses three approaches:
  1. Per-pair ratios (only where both deltas are nonzero)
  2. Per-session aggregate: total weekly delta / total session delta across a whole session
  3. Linear regression (OLS) of weekly delta on session delta
"""

import json
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path

DATA_PATH = Path.home() / ".config/clacal/usage_data.json"
GAP_THRESHOLD = 15.0  # minutes
MIN_DELTA_SESSION = 0.5  # minimum session delta for per-pair ratio

raw = json.loads(DATA_PATH.read_text())
polls = sorted(raw["polls"], key=lambda p: p["timestamp"])
sessions = sorted(raw.get("sessions", []), key=lambda s: s["timestamp"])
session_times = sorted(s["timestamp"] for s in sessions)


def spans_session(t0: float, t1: float) -> bool:
    return any(t0 < st <= t1 for st in session_times)


def find_session_idx(ts: float) -> int:
    """Which session does this timestamp belong to (index into session_times)."""
    idx = 0
    for i, st in enumerate(session_times):
        if ts >= st:
            idx = i
    return idx


# ══════════════════════════════════════════════════════════════════════════
# Approach 1: Per-pair ratios (filtering zero-delta-weekly pairs)
# ══════════════════════════════════════════════════════════════════════════

pairs: list[dict] = []

for i in range(1, len(polls)):
    prev, curr = polls[i - 1], polls[i]
    t0, t1 = prev["timestamp"], curr["timestamp"]
    gap_min = (t1 - t0) / 60

    if gap_min <= 0 or gap_min > GAP_THRESHOLD:
        continue
    if spans_session(t0, t1):
        continue

    ds = curr["sessionUsage"] - prev["sessionUsage"]
    dw = curr["weeklyUsage"] - prev["weeklyUsage"]

    pairs.append({
        "timestamp": t1,
        "dt": datetime.fromtimestamp(t1),
        "delta_session": ds,
        "delta_weekly": dw,
        "session_usage": curr["sessionUsage"],
        "weekly_usage": curr["weeklyUsage"],
    })

# All valid pairs (including dw=0)
all_ds = [p["delta_session"] for p in pairs if p["delta_session"] > MIN_DELTA_SESSION]
all_dw = [p["delta_weekly"] for p in pairs if p["delta_session"] > MIN_DELTA_SESSION]

# Only pairs where weekly actually moved
nonzero = [p for p in pairs if p["delta_session"] > MIN_DELTA_SESSION and p["delta_weekly"] > 0]
nz_ratios = [p["delta_weekly"] / p["delta_session"] for p in nonzero]

print(f"Total polls:              {len(polls)}")
print(f"Valid consecutive pairs:  {len(pairs)}")
print(f"  with ds > {MIN_DELTA_SESSION}:           {len(all_ds)}")
print(f"  with ds > {MIN_DELTA_SESSION} AND dw > 0: {len(nonzero)}")
print(f"  fraction with dw=0:     {1 - len(nonzero)/len(all_ds):.1%}")
print()

# ── Per-pair stats (nonzero dw only) ─────────────────────────────────────

print("═══ Approach 1: Per-pair ratio (dw/ds, only where dw>0) ═══")
if nz_ratios:
    print(f"  n:       {len(nz_ratios)}")
    print(f"  Mean:    {statistics.mean(nz_ratios):.6f}")
    print(f"  Median:  {statistics.median(nz_ratios):.6f}")
    print(f"  Std:     {statistics.stdev(nz_ratios):.6f}")
    print(f"  Min:     {min(nz_ratios):.6f}")
    print(f"  Max:     {max(nz_ratios):.6f}")
    sv = sorted(nz_ratios)
    n = len(sv)
    for pct in [10, 25, 50, 75, 90]:
        print(f"  P{pct:02d}:    {sv[min(int(n * pct / 100), n-1)]:.6f}")
else:
    print("  No pairs with both deltas > 0")

print()

# ══════════════════════════════════════════════════════════════════════════
# Approach 2: Per-session aggregate ratio
# ══════════════════════════════════════════════════════════════════════════

print("═══ Approach 2: Per-session aggregate (Σdw / Σds) ═══")

# Group polls by session
session_polls: dict[int, list] = defaultdict(list)
for p in polls:
    idx = find_session_idx(p["timestamp"])
    session_polls[idx].append(p)

session_ratios: list[dict] = []
for idx in sorted(session_polls):
    sp = session_polls[idx]
    if len(sp) < 2:
        continue
    # total session usage consumed in this session
    total_ds = sp[-1]["sessionUsage"] - sp[0]["sessionUsage"]
    total_dw = sp[-1]["weeklyUsage"] - sp[0]["weeklyUsage"]
    if total_ds < 1:
        continue
    session_ratios.append({
        "session_idx": idx,
        "n_polls": len(sp),
        "total_ds": total_ds,
        "total_dw": total_dw,
        "ratio": total_dw / total_ds,
        "start": datetime.fromtimestamp(sp[0]["timestamp"]),
        "max_session_usage": sp[-1]["sessionUsage"],
    })

if session_ratios:
    sr_vals = [s["ratio"] for s in session_ratios]
    print(f"  Sessions with data: {len(session_ratios)}")
    print(f"  Mean:    {statistics.mean(sr_vals):.6f}")
    print(f"  Median:  {statistics.median(sr_vals):.6f}")
    print(f"  Std:     {statistics.stdev(sr_vals):.6f}" if len(sr_vals) >= 2 else "")
    print(f"  Min:     {min(sr_vals):.6f}")
    print(f"  Max:     {max(sr_vals):.6f}")
    print()
    print("  Per-session detail:")
    for s in session_ratios:
        print(f"    {s['start'].strftime('%m-%d %H:%M')}  "
              f"polls={s['n_polls']:3d}  "
              f"Σds={s['total_ds']:6.1f}%  "
              f"Σdw={s['total_dw']:6.1f}%  "
              f"ratio={s['ratio']:.6f}  "
              f"maxSU={s['max_session_usage']:.0f}%")

print()

# ══════════════════════════════════════════════════════════════════════════
# Approach 3: OLS regression  dw = β * ds  (no intercept)
# ══════════════════════════════════════════════════════════════════════════

print("═══ Approach 3: OLS regression (dw = β·ds, no intercept) ═══")
# Use all valid pairs (including dw=0 — that's real data)
valid = [p for p in pairs if p["delta_session"] > MIN_DELTA_SESSION]

if valid:
    ds_list = [p["delta_session"] for p in valid]
    dw_list = [p["delta_weekly"] for p in valid]
    sum_ds_sq = sum(x**2 for x in ds_list)
    sum_ds_dw = sum(x * y for x, y in zip(ds_list, dw_list))
    beta = sum_ds_dw / sum_ds_sq if sum_ds_sq else 0

    # R² for no-intercept model
    ss_res = sum((y - beta * x) ** 2 for x, y in zip(ds_list, dw_list))
    ss_tot = sum(y**2 for y in dw_list)
    r_sq = 1 - ss_res / ss_tot if ss_tot else 0

    print(f"  β (slope):  {beta:.6f}")
    print(f"  R²:         {r_sq:.4f}")
    print(f"  n:          {len(valid)}")

print()

# ══════════════════════════════════════════════════════════════════════════
# Approach 4: macro ratio over entire dataset
# ══════════════════════════════════════════════════════════════════════════

print("═══ Approach 4: Macro ratio (total Σdw / total Σds across all pairs) ═══")
if valid:
    total_ds_all = sum(p["delta_session"] for p in valid)
    total_dw_all = sum(p["delta_weekly"] for p in valid)
    print(f"  Total Σds: {total_ds_all:.2f}%")
    print(f"  Total Σdw: {total_dw_all:.2f}%")
    print(f"  Macro ratio: {total_dw_all / total_ds_all:.6f}" if total_ds_all else "  n/a")

print()

# ══════════════════════════════════════════════════════════════════════════
# Variation analysis: is it constant across sessions?
# ══════════════════════════════════════════════════════════════════════════

print("═══ Constancy analysis ═══")
if session_ratios and len(session_ratios) >= 2:
    sr_vals = [s["ratio"] for s in session_ratios]
    mean_sr = statistics.mean(sr_vals)
    std_sr = statistics.stdev(sr_vals)
    cov = std_sr / mean_sr if mean_sr else float("inf")
    print(f"  Per-session ratio CoV: {cov:.4f}")
    print(f"  Range: [{min(sr_vals):.6f}, {max(sr_vals):.6f}]")

    if cov < 0.05:
        verdict = "CONSTANT — virtually no variation across sessions"
    elif cov < 0.15:
        verdict = "MOSTLY constant — minor session-to-session variation"
    elif cov < 0.30:
        verdict = "MODERATE variation — exchange rate shifts between sessions"
    else:
        verdict = "HIGHLY variable — not a reliable constant"
    print(f"  Verdict: {verdict}")

print()

# ══════════════════════════════════════════════════════════════════════════
# Filtered per-session analysis (exclude resets & tiny sessions)
# ══════════════════════════════════════════════════════════════════════════

print("═══ Filtered per-session (Σds ≥ 10%, ratio ≥ 0) ═══")
filtered = [s for s in session_ratios if s["total_ds"] >= 10 and s["ratio"] >= 0]
if filtered:
    fv = [s["ratio"] for s in filtered]
    mean_f = statistics.mean(fv)
    med_f = statistics.median(fv)
    std_f = statistics.stdev(fv) if len(fv) >= 2 else 0
    cov_f = std_f / mean_f if mean_f else float("inf")
    print(f"  n:       {len(fv)}")
    print(f"  Mean:    {mean_f:.6f}")
    print(f"  Median:  {med_f:.6f}")
    print(f"  Std:     {std_f:.6f}")
    print(f"  CoV:     {cov_f:.4f}")
    print(f"  Min:     {min(fv):.6f}")
    print(f"  Max:     {max(fv):.6f}")
    print()

    # Check if 1/12 ≈ 0.08333 is a good fit
    print(f"  Hypothesis: rate = 1/12 = {1/12:.6f}")
    deviations = [abs(v - 1/12) for v in fv]
    print(f"  Mean |deviation| from 1/12: {statistics.mean(deviations):.6f}")
    print(f"  Max  |deviation| from 1/12: {max(deviations):.6f}")

    if cov_f < 0.05:
        verdict = "CONSTANT"
    elif cov_f < 0.15:
        verdict = "MOSTLY constant"
    elif cov_f < 0.30:
        verdict = "MODERATE variation"
    else:
        verdict = "HIGHLY variable"
    print(f"  Verdict: {verdict} (CoV={cov_f:.4f})")

print()
print(f"  Hardcoded EXCHANGE_RATE:  0.12")
print(f"  Empirical median (filt): {med_f:.6f}" if filtered else "")
print(f"  1/12:                     {1/12:.6f}")
print(f"  Sessions × rate ≈ weekly: ~{1/med_f:.1f} full sessions fill a week" if filtered and med_f > 0 else "")
