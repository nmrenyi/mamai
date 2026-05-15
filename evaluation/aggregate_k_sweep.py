#!/usr/bin/env python3
"""Aggregate per-k latency-sweep JSONs into a single GPU↔CPU comparison report.

Reads all benchmark_*.json files produced by benchmark_latency.py, groups them
by (backend, k_override), and writes a markdown report at
evaluation/reports/latency_report_v2.md.

Notes on backend identification: post-fix benchmark JSONs (commit ef96538
onward) record `backend` correctly and are trusted as-is. Pre-fix GPU sweep
JSONs hard-code `backend="CPU"` even though they were measured on GPU; we
backfill those using an explicit filename allowlist (see `backend_of`).
Future runs of any backend are unaffected.
"""
from __future__ import annotations

import datetime
import glob
import json
import os
import statistics
import sys
from collections import defaultdict
from pathlib import Path

# Backfill for the specific historical GPU sweep files that predate the
# metadata-recording fix in commit ef96538. Those JSONs hard-code
# config.backend="CPU" even though they were measured on GPU. We use an
# explicit filename allowlist (rather than a timestamp threshold) so the
# rewrite cannot accidentally fire on anyone else's pre-threshold *genuine
# CPU* JSONs that happen to share latency_results/.
PRE_FIX_GPU_FILES = frozenset({
    "benchmark_20260514T174502_k1.json",
    "benchmark_20260514T180830_k3.json",
    "benchmark_20260514T183604_k5.json",
    "benchmark_20260514T190438_k7.json",
    "benchmark_20260514T193453_k10.json",
    "benchmark_20260514T200414_k15.json",
    "benchmark_20260514T203653_k20.json",
    "benchmark_20260514T210522.json",
})


def backend_of(filename: str, recorded: str) -> str:
    """Trust the recorded backend except for the listed pre-fix GPU files."""
    if filename in PRE_FIX_GPU_FILES:
        return "GPU"
    return recorded


def load_runs() -> list[dict]:
    files = sorted(glob.glob(os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "latency_results", "benchmark_*.json",
    )))
    runs = []
    for f in files:
        try:
            with open(f) as fp:
                d = json.load(fp)
        except (json.JSONDecodeError, OSError):
            continue
        if "config" not in d or "results" not in d:
            continue
        if len(d["results"]) < 30:
            continue  # skip ad-hoc smoke tests; the canonical sweep is 54 runs
        ts = os.path.basename(f).replace("benchmark_", "").split(".")[0].split("_")[0]
        k_override = d["config"].get("retrieval_top_k_override")
        skip_retrieval = d["config"].get("skip_retrieval", False)
        k_label = 0 if skip_retrieval else (k_override if k_override is not None else None)
        if k_label is None:
            continue
        # The metadata fix in commit ef96538 ensures post-fix runs record
        # config.backend. If it's missing, the JSON predates that fix — only
        # safe if the filename is on the allowlist; otherwise warn loudly
        # rather than silently defaulting (which would mask future GPU runs
        # written by a regressed BenchmarkForegroundService).
        recorded_backend = d["config"].get("backend")
        if recorded_backend is None:
            if os.path.basename(f) not in PRE_FIX_GPU_FILES:
                print(
                    f"WARN: {os.path.basename(f)} has no config.backend "
                    "field and is not on the pre-fix allowlist; defaulting "
                    "to CPU. If this was actually a GPU run, fix the source.",
                    file=sys.stderr,
                )
            recorded_backend = "CPU"
        backend = backend_of(os.path.basename(f), recorded_backend)
        runs.append({
            "file": os.path.basename(f),
            "timestamp": ts,
            "backend": backend,
            "k": k_label,
            "data": d,
        })
    return runs


def aggregate_per_category(d: dict, key: str) -> dict[str, dict]:
    """Per-category {median, p95, n} for the given timing field."""
    cat_vals: dict[str, list] = defaultdict(list)
    for r in d["results"]:
        if r.get("error"):
            continue
        cat_vals[r["category"]].append(r[key])
    out = {}
    for c, vs in cat_vals.items():
        if not vs:
            continue
        s = sorted(vs)
        out[c] = {
            "n": len(vs),
            "median": int(statistics.median(vs)),
            "p95": int(s[min(len(s) - 1, int(len(s) * 0.95))]),
        }
    return out


def aggregate_overall(d: dict, key: str) -> dict:
    vs = [r[key] for r in d["results"] if not r.get("error")]
    if not vs:
        return {}
    s = sorted(vs)
    return {
        "n": len(vs),
        "median": int(statistics.median(vs)),
        "p95": int(s[min(len(s) - 1, int(len(s) * 0.95))]),
    }


def median_doc_chars(d: dict) -> int:
    """Median retrieved_total_chars across successful runs (the table column
    is labeled 'doc_chars med', so this is the median by definition)."""
    vs = [r.get("retrieved_total_chars", 0) for r in d["results"] if not r.get("error")]
    return int(statistics.median(vs)) if vs else 0


def fmt_ms(v: int | None) -> str:
    return f"{v}" if v is not None else "—"


def fmt_s(v: int | None) -> str:
    return f"{v / 1000:.1f}" if v is not None else "—"


def write_report(runs: list[dict], out_path: Path) -> None:
    # Build {(backend, k) -> latest canonical run}
    matrix: dict[tuple[str, int], dict] = {}
    for r in runs:
        key = (r["backend"], r["k"])
        if key in matrix:
            # Keep the run with most successful entries (resolves duplicates)
            ex = matrix[key]
            ex_ok = sum(1 for x in ex["data"]["results"] if not x.get("error"))
            r_ok = sum(1 for x in r["data"]["results"] if not x.get("error"))
            if r_ok > ex_ok:
                matrix[key] = r
        else:
            matrix[key] = r

    gpu_ks = sorted([k for (b, k) in matrix if b == "GPU"])
    cpu_ks = sorted([k for (b, k) in matrix if b == "CPU"])
    all_ks = sorted(set(gpu_ks + cpu_ks))

    # Sample run for device info
    sample = next(iter(matrix.values()))
    dev = sample["data"]["device"]

    md = []
    md.append("# MAM-AI On-Device Latency Sweep — GPU vs CPU\n")
    md.append(f"_Generated: {datetime.datetime.now().isoformat(timespec='seconds')}_\n")
    md.append("")
    md.append("## Device & stack\n")
    md.append(f"- **Device**: {dev.get('manufacturer', '?')} {dev.get('model', '?')} ({dev.get('soc', '?')}) — Android {dev.get('android_version', '?')}")
    md.append(f"- **Model**: Gemma 4 E4B (`gemma-4-E4B-it.litertlm`)")
    md.append(f"- **LiteRT-LM**: 0.11.0")
    md.append(f"- **Backends tested**: GPU (OpenCL, via `useGpuForLlm=true`) and CPU")
    md.append(f"- **Sampling**: temp=1.0, top_p=0.95, top_k=64, max_tokens=32000")
    md.append("")
    md.append("## Methodology\n")
    md.append("Per backend × k configuration: 18 queries × 1 mode (RAG-only) × 3 repeats = 54 timed runs. ")
    md.append("Plus a No-RAG baseline per backend (k=0 via `--no-retrieval`). 10-second cooldown between runs ")
    md.append("for thermal stability. Activity → ForegroundService with PARTIAL_WAKE_LOCK so the run survives ")
    md.append("screen-off and device-lock; OPPO Hans whitelist set manually.")
    md.append("")
    md.append("- `TTFT` excludes retrieval — measured from end-of-retrieval to first generated token.")
    md.append("- `decode` is first-token to last-token.")
    md.append("- `total_query` is everything: `retrieval + TTFT + decode`.")
    md.append("- Reported as median across the 54 runs unless noted (p95 in tables marked `p95`).")
    md.append("")

    # ─────────── Headline table: total_query_ms by (backend, k) ───────────
    md.append("## Headline — Median total query latency (seconds)\n")
    md.append(f"| k | doc_chars med | GPU short / med / long | CPU short / med / long | CPU÷GPU |")
    md.append(f"|---:|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get(("GPU", k))
        cpu_run = matrix.get(("CPU", k))
        # doc chars: take from GPU if available, else CPU
        doc_chars = median_doc_chars(gpu_run["data"] if gpu_run else cpu_run["data"]) if (gpu_run or cpu_run) else 0
        gpu_cells = "—"
        cpu_cells = "—"
        if gpu_run:
            g = aggregate_per_category(gpu_run["data"], "total_query_ms")
            gpu_cells = " / ".join(fmt_s(g.get(c, {}).get("median")) for c in ["short", "medium", "long"])
        if cpu_run:
            c_ = aggregate_per_category(cpu_run["data"], "total_query_ms")
            cpu_cells = " / ".join(fmt_s(c_.get(c, {}).get("median")) for c in ["short", "medium", "long"])
        # ratio
        ratio = ""
        if gpu_run and cpu_run:
            gov = aggregate_overall(gpu_run["data"], "total_query_ms").get("median")
            cov = aggregate_overall(cpu_run["data"], "total_query_ms").get("median")
            if gov is not None and cov is not None and gov > 0:
                ratio = f"{cov / gov:.2f}×"
        label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {label} | {doc_chars} | {gpu_cells} | {cpu_cells} | {ratio} |")
    md.append("")

    # ─────────── TTFT detail ───────────
    md.append("## TTFT (ms, median) — prefill cost grows with retrieved-doc content\n")
    md.append(f"| k | doc_chars med | GPU TTFT | CPU TTFT | CPU÷GPU |")
    md.append(f"|---:|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get(("GPU", k))
        cpu_run = matrix.get(("CPU", k))
        doc_chars = median_doc_chars(gpu_run["data"] if gpu_run else cpu_run["data"]) if (gpu_run or cpu_run) else 0
        gv = aggregate_overall(gpu_run["data"], "ttft_ms").get("median") if gpu_run else None
        cv = aggregate_overall(cpu_run["data"], "ttft_ms").get("median") if cpu_run else None
        # Explicit None checks; also guard against div-by-zero on a 0 median.
        ratio = f"{cv / gv:.1f}×" if (gv is not None and cv is not None and gv > 0) else ""
        label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {label} | {doc_chars} | {fmt_ms(gv)} | {fmt_ms(cv)} | {ratio} |")
    md.append("")

    # ─────────── Decode detail ───────────
    md.append("## Decode (ms, median) — first token to last token\n")
    md.append("Decode time mostly tracks output length, not k or doc content. Variation across k reflects ")
    md.append("the model writing *longer answers* when given more context (more material to draw on).")
    md.append("")
    md.append(f"| k | GPU decode | CPU decode | CPU÷GPU |")
    md.append(f"|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get(("GPU", k))
        cpu_run = matrix.get(("CPU", k))
        gv = aggregate_overall(gpu_run["data"], "decode_ms").get("median") if gpu_run else None
        cv = aggregate_overall(cpu_run["data"], "decode_ms").get("median") if cpu_run else None
        ratio = f"{cv / gv:.2f}×" if (gv is not None and cv is not None and gv > 0) else ""
        label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {label} | {fmt_ms(gv)} | {fmt_ms(cv)} | {ratio} |")
    md.append("")

    # ─────────── p95 totals ───────────
    md.append("## p95 total query latency (s) — tail-latency view\n")
    md.append(f"| k | GPU p95 | CPU p95 |")
    md.append(f"|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get(("GPU", k))
        cpu_run = matrix.get(("CPU", k))
        gv = aggregate_overall(gpu_run["data"], "total_query_ms").get("p95") if gpu_run else None
        cv = aggregate_overall(cpu_run["data"], "total_query_ms").get("p95") if cpu_run else None
        label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {label} | {fmt_s(gv)} | {fmt_s(cv)} |")
    md.append("")

    # ─────────── Errors / context limit ───────────
    md.append("## Errors and the 4096-token context wall\n")
    md.append(f"| k | GPU errors / 54 | CPU errors / 54 |")
    md.append(f"|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get(("GPU", k))
        cpu_run = matrix.get(("CPU", k))
        ge = sum(1 for r in gpu_run["data"]["results"] if r.get("error")) if gpu_run else None
        ce = sum(1 for r in cpu_run["data"]["results"] if r.get("error")) if cpu_run else None
        label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {label} | {fmt_ms(ge)} | {fmt_ms(ce)} |")
    md.append("")
    md.append("At k=20, **24 of 54 runs failed on both GPU and CPU** with `Input token ids are too long. ")
    md.append("Exceeding the maximum number of tokens allowed: …>= 4096`. The **exact same 8 queries failed on both ")
    md.append("backends** (`long_01, long_03, medium_02, medium_04, short_01, short_03, short_04, short_05`) — ")
    md.append("the same 24 (query × rep) pairs. This is direct evidence that the 4096-token cap is a property of ")
    md.append("the Gemma 4 E4B `.litertlm` artifact itself, not a runtime configuration, not a backend choice. ")
    md.append("The other 10 queries (10 × 3 reps = 30 successful runs) were the ones whose retrieved chunks happened to be shorter.")
    md.append("")
    md.append("Successful-run timing at CPU k=20: TTFT 65–73 s, total 89–96 s — confirming CPU is well past any ")
    md.append("deployment budget at this depth even when the request fits in the context window.")
    md.append("")

    # ─────────── Wall-clock comparison ───────────
    md.append("## Wall-clock comparison\n")
    md.append("| k | GPU wall (min) | CPU wall (min) | CPU÷GPU |")
    md.append("|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get(("GPU", k))
        cpu_run = matrix.get(("CPU", k))
        gw = gpu_run["data"]["total_benchmark_time_ms"] / 60000 if gpu_run else None
        cw = cpu_run["data"]["total_benchmark_time_ms"] / 60000 if cpu_run else None
        gw_s = f"{gw:.1f}" if gw is not None else "—"
        cw_s = f"{cw:.1f}" if cw is not None else "—"
        ratio = f"{cw / gw:.2f}×" if (gw is not None and cw is not None and gw > 0) else ""
        label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {label} | {gw_s} | {cw_s} | {ratio} |")

    # Findings / interpretation
    md.append("")
    md.append("## Key findings\n")
    md.append("")
    md.append("### 1. GPU is the practical choice for this workload on Snapdragon 8 Elite")
    md.append("GPU TTFT runs around **1–3.5 s** across k=0–15. CPU TTFT runs around **12.6 s (no-RAG) → 55 s (k=15)**. ")
    md.append("That's a 13–19× TTFT speedup from GPU. Decode time is largely backend-invariant (memory-bandwidth-bound), ")
    md.append("so the *total* speedup is closer to 2–3.5× — but those seconds of TTFT translate directly to perceived UX latency.")
    md.append("")
    md.append("### 2. The model's 4096-token context window is the binding ceiling at high k")
    md.append("k=15 works cleanly (54/54 on both GPU and CPU). k=20 fails identically on **both backends** — ")
    md.append("the **exact same 24 of 54 runs (8 queries × 3 reps)** error with `Input token ids are too long … >= 4096`. ")
    md.append("Same queries fail on both because the chunks retrieved are deterministic and chunk length × k drives ")
    md.append("the prompt past the window. The 4096-token cap is a property of the `.litertlm` model artifact, ")
    md.append("not a runtime config and not a backend choice. **k_max ≈ 17–18** for this artifact. ")
    md.append("Latency is *not* the constraint at the upper end; the model's context window is.")
    md.append("")
    md.append("### 3. Latency is not the binding factor on GPU below k=15")
    md.append("GPU total medians stay between 13 s (no-RAG) and 25 s (k=15) — all well under any reasonable UX budget. ")
    md.append("Picking k* should be driven by **answer quality** (do more chunks help or hurt the small generator?), ")
    md.append("not by what fits in the latency budget.")
    md.append("")
    md.append("### 4. CPU at k≥5 hits any reasonable UX budget; at k=15 it's prohibitively slow")
    md.append("CPU totals: k=3 → 37–44 s, k=5 → 55–63 s, k=7 → 60–62 s, k=10 → 62–78 s, k=15 → 81–90 s. ")
    md.append("p95 at CPU k=15 hits **113 s** — almost two minutes for the slowest 5% of queries. If GPU isn't ")
    md.append("available (lower-tier devices), the practical CPU operating point is **k ≤ 3** for a sub-60s budget, ")
    md.append("or **k ≤ 1** if you want sub-40s p95.")
    md.append("")
    md.append("### 5. Decode time is content-driven, not k-driven")
    md.append("Decode time tracks output length. As k grows, the model writes *longer* responses — likely because ")
    md.append("more context = more material to weave in. This is a quality-coupled latency effect, not a prefill effect. ")
    md.append("Decode-time difference between GPU and CPU is only ~1.1–1.4× across all k, since decode is memory-bandwidth-bound, ")
    md.append("not compute-bound on this hardware.")
    md.append("")
    md.append("### 6. TTFT scales linearly with retrieved-doc content past k=3")
    md.append("On both backends, TTFT per added doc-char is roughly constant past k=3: GPU ~100–250 µs/char, ")
    md.append("CPU ~3,500–5,000 µs/char. The GPU↔CPU ratio is stable at ~13–19× across the prefill range, suggesting ")
    md.append("the GPU primarily speeds up the *compute-heavy* prefill phase while decode stays bandwidth-bound on both.")
    md.append("")

    # File inventory
    md.append("## Data inventory (per `(backend, k)`)\n")
    md.append("| Backend | k | File | Wall (min) | Runs | Errors |")
    md.append("|---|---:|---|---:|---:|---:|")
    for (b, k) in sorted(matrix.keys(), key=lambda x: (x[0], x[1])):
        r = matrix[(b, k)]
        wall = r["data"]["total_benchmark_time_ms"] / 60000
        n = len(r["data"]["results"])
        e = sum(1 for x in r["data"]["results"] if x.get("error"))
        label = "0 (no-RAG)" if k == 0 else str(k)
        md.append(f"| {b} | {label} | `{r['file']}` | {wall:.1f} | {n} | {e} |")
    md.append("")
    md.append("---")
    md.append("")
    md.append("_Source benchmark JSONs live in `evaluation/latency_results/`. ")
    md.append("Aggregation script: `evaluation/aggregate_k_sweep.py`._")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(md) + "\n")
    print(f"Report written to: {out_path}")


def main() -> int:
    runs = load_runs()
    print(f"Loaded {len(runs)} canonical runs")
    out = Path(__file__).resolve().parent / "reports" / "latency_report_v2.md"
    write_report(runs, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
