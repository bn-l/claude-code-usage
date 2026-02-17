from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from constants import N_MW_WEEKS, POLL_INTERVAL, SESSION_MIN, Poll
from helpers import weekly_deviation, weekly_expected, session_target


# ════════════════════════════════════════════════════════════════════════
#  OPEN-LOOP ANALYSIS
# ════════════════════════════════════════════════════════════════════════


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


# ════════════════════════════════════════════════════════════════════════
#  CLOSED-LOOP ANALYSIS
# ════════════════════════════════════════════════════════════════════════


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


# ════════════════════════════════════════════════════════════════════════
#  OUTPUT / FORMATTING
# ════════════════════════════════════════════════════════════════════════


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
#  MULTI-WEEK ADAPTIVE OUTPUT
# ════════════════════════════════════════════════════════════════════════


def print_mw_learning_curve(
    per_week: dict[str, dict[str, dict[int, list[CLRunStats]]]],
    algo_names: list[str],
):
    # Aggregate across compliance × profiles per (algo, week)
    agg_wu: dict[str, list[float]] = {a: [] for a in algo_names}
    agg_cal: dict[str, list[float]] = {a: [] for a in algo_names}
    agg_sat: dict[str, list[float]] = {a: [] for a in algo_names}

    for w in range(N_MW_WEEKS):
        for aname in algo_names:
            stats = [
                s
                for cname in per_week
                for s in per_week[cname][aname][w]
            ]
            if stats:
                agg_wu[aname].append(float(np.mean([s.final_wu for s in stats])))
                agg_cal[aname].append(float(np.mean([s.cal_mean_abs for s in stats])))
                agg_sat[aname].append(float(np.mean([s.saturation_pct for s in stats])))
            else:
                agg_wu[aname].append(0.0)
                agg_cal[aname].append(0.0)
                agg_sat[aname].append(0.0)

    print("### Learning Curve — Utilization (Final WU %)\n")
    print("| Week | " + " | ".join(algo_names) + " |")
    print("|------|" + "-------:|" * len(algo_names))
    for w in range(N_MW_WEEKS):
        cells = [f"{agg_wu[a][w]:.1f}" for a in algo_names]
        print(f"| {w + 1} | " + " | ".join(cells) + " |")
    print()

    print("### Learning Curve — Signal Quality (mean |cal|)\n")
    print("| Week | " + " | ".join(algo_names) + " |")
    print("|------|" + "-------:|" * len(algo_names))
    for w in range(N_MW_WEEKS):
        cells = [f"{agg_cal[a][w]:.3f}" for a in algo_names]
        print(f"| {w + 1} | " + " | ".join(cells) + " |")
    print()

    print("### Learning Curve — Saturation %\n")
    print("| Week | " + " | ".join(algo_names) + " |")
    print("|------|" + "-------:|" * len(algo_names))
    for w in range(N_MW_WEEKS):
        cells = [f"{agg_sat[a][w]:.1f}" for a in algo_names]
        print(f"| {w + 1} | " + " | ".join(cells) + " |")
    print()

    # Signal efficiency: WU gain per unit |cal|
    active = [a for a in algo_names if a != "No Feedback"]
    print("### Signal Efficiency (WU gain / mean |cal|)\n")
    print("_Higher = more utilization per unit of signal annoyance_\n")
    print("| Week | " + " | ".join(active) + " |")
    print("|------|" + "-------:|" * len(active))
    for w in range(N_MW_WEEKS):
        base_wu = agg_wu["No Feedback"][w] if "No Feedback" in agg_wu else 33.7
        cells = []
        for a in active:
            improvement = agg_wu[a][w] - base_wu
            eff = improvement / max(agg_cal[a][w], 0.001)
            cells.append(f"{eff:.1f}")
        print(f"| {w + 1} | " + " | ".join(cells) + " |")
    print()


def print_mw_per_compliance(
    per_week: dict[str, dict[str, dict[int, list[CLRunStats]]]],
    algo_names: list[str],
):
    for cname in per_week:
        print(f"### {cname} — WU by Week\n")
        print("| Week | " + " | ".join(algo_names) + " |")
        print("|------|" + "-------:|" * len(algo_names))
        for w in range(N_MW_WEEKS):
            cells = []
            for a in algo_names:
                stats = per_week[cname][a][w]
                val = float(np.mean([s.final_wu for s in stats])) if stats else 0
                cells.append(f"{val:.1f}")
            print(f"| {w + 1} | " + " | ".join(cells) + " |")
        print()


def print_mw_convergence(
    convergence: dict[str, dict[int, list]],
    compliance_profiles: dict,
):
    print("### Parameter Convergence — Adaptive\n")
    print("| Compliance | True DZ | Est DZ (wk1) | Est DZ (wk8) "
          "| Est Gain (wk1) | Est Gain (wk8) | Conf (wk8) "
          "| True Delay | Est Delay (wk8) |")
    print("|------------|---------|--------------|-------------- "
          "|----------------|----------------|------------ "
          "|------------|-----------------|")

    for cname in compliance_profiles:
        true_dz = compliance_profiles[cname]["dead_zone"]
        true_delay = compliance_profiles[cname]["delay"]
        wk1 = convergence[cname].get(0, [])
        wk8 = convergence[cname].get(N_MW_WEEKS - 1, [])

        dz1 = float(np.mean([c[1] for c in wk1])) if wk1 else 0
        g1 = float(np.mean([c[0] for c in wk1])) if wk1 else 0
        dz8 = float(np.mean([c[1] for c in wk8])) if wk8 else 0
        g8 = float(np.mean([c[0] for c in wk8])) if wk8 else 0
        conf8 = float(np.mean([c[2] for c in wk8])) if wk8 else 0
        delay8 = float(np.mean([c[3] for c in wk8 if len(c) > 3])) if wk8 else 1

        print(f"| {cname} | {true_dz:.2f} | {dz1:.2f} | {dz8:.2f} "
              f"| {g1:.3f} | {g8:.3f} | {conf8:.2f} "
              f"| {true_delay} | {delay8:.1f} |")
    print()
