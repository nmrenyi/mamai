#!/usr/bin/env python3
"""Aggregate per-k latency-sweep JSONs into a single model × backend × k report.

Reads all benchmark_*.json files produced by benchmark_latency.py, groups them
by (model, backend, k_override), and writes a markdown report at
evaluation/reports/latency_report_v2.md.

Notes on backend identification: post-fix benchmark JSONs (commit ef96538
onward) record `backend` correctly and are trusted as-is. Pre-fix GPU sweep
JSONs hard-code `backend="CPU"` even though they were measured on GPU; we
backfill those using an explicit filename allowlist (see `backend_of`).

Notes on model identification: post-fix JSONs (commit 976a8ac onward) record
`config.model` from the app asset; earlier runs do not. For any JSON missing
`config.model` we default to `gemma-4-E4B-it.litertlm` since the only sweeps
that predate the fix were E4B. Future runs of any model are unaffected.
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


# Default model for any pre-fix JSON missing config.model. All such files in
# the current repo are E4B; this default is purely defensive in case an old
# JSON resurfaces. New runs always record their own model.
LEGACY_DEFAULT_MODEL = "gemma-4-E4B-it.litertlm"


def model_of(filename: str, recorded: str | None) -> str:
    """Trust the recorded model; default to E4B for legacy JSONs that lack it."""
    if recorded is not None:
        return recorded
    return LEGACY_DEFAULT_MODEL


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
            print(f"SKIP: {os.path.basename(f)} — missing config or results key", file=sys.stderr)
            continue
        if len(d["results"]) < 30:
            # Skip ad-hoc smoke tests (the canonical sweep is 54 runs). Log so
            # that a legitimate narrow sweep (--filter long_01, single-category)
            # isn't silently dropped from the report.
            print(
                f"SKIP: {os.path.basename(f)} — {len(d['results'])} results "
                "(< 30 threshold for canonical sweeps; pass it through if it "
                "should appear in the matrix)",
                file=sys.stderr,
            )
            continue
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
        recorded_model = d["config"].get("model")
        if recorded_model is None:
            print(
                f"WARN: {os.path.basename(f)} has no config.model field; "
                f"defaulting to {LEGACY_DEFAULT_MODEL}. If this was a "
                "different model, the JSON predates the model-recording fix.",
                file=sys.stderr,
            )
        model = model_of(os.path.basename(f), recorded_model)
        runs.append({
            "file": os.path.basename(f),
            "timestamp": ts,
            "model": model,
            "backend": backend,
            "k": k_label,
            "data": d,
        })
    return runs


def _p95(values: list[float]) -> int | None:
    """95th percentile via linear-interpolation 20-quantile partition.

    `statistics.quantiles(data, n=20)` returns 19 cut points dividing the
    data into 20 equal-frequency groups; index 18 is the 95th percentile.
    For very small samples (n < 2), there are no cut points to compute,
    so we fall back to max — same behaviour as the previous
    `int(len(s)*0.95)` formula but without the off-by-one that made p95
    collapse to max for any n < 20.
    """
    if not values:
        return None
    if len(values) < 2:
        return int(values[0])
    return int(statistics.quantiles(values, n=20, method="exclusive")[18])


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
        out[c] = {
            "n": len(vs),
            "median": int(statistics.median(vs)),
            "p95": _p95(vs),
        }
    return out


def aggregate_overall(d: dict, key: str) -> dict:
    vs = [r[key] for r in d["results"] if not r.get("error")]
    if not vs:
        return {}
    return {
        "n": len(vs),
        "median": int(statistics.median(vs)),
        "p95": _p95(vs),
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


def _short_model_label(model: str) -> str:
    """Human-friendly short label, e.g. 'Gemma 4 E4B' for 'gemma-4-E4B-it.litertlm'."""
    if "E4B" in model:
        return "Gemma 4 E4B"
    if "E2B" in model:
        return "Gemma 4 E2B"
    return model


def _write_per_model_section(
    md: list[str], matrix: dict, model: str, all_ks: list[int]
) -> None:
    """Emit the six per-model tables (headline / TTFT / decode / p95 / errors / wall-clock).

    Each table follows the same `(GPU, CPU, ratio)` shape as the original
    single-model report; we just scope to one model at a time.
    """
    label = _short_model_label(model)
    md.append(f"## {label} (`{model}`)\n")

    md.append("### Median total query latency (seconds)\n")
    md.append("| k | doc_chars med | GPU short / med / long | CPU short / med / long | CPU÷GPU |")
    md.append("|---:|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get((model, "GPU", k))
        cpu_run = matrix.get((model, "CPU", k))
        if not gpu_run and not cpu_run:
            continue
        doc_chars = median_doc_chars(gpu_run["data"] if gpu_run else cpu_run["data"])
        gpu_cells = "—"
        cpu_cells = "—"
        if gpu_run:
            g = aggregate_per_category(gpu_run["data"], "total_query_ms")
            gpu_cells = " / ".join(fmt_s(g.get(c, {}).get("median")) for c in ["short", "medium", "long"])
        if cpu_run:
            c_ = aggregate_per_category(cpu_run["data"], "total_query_ms")
            cpu_cells = " / ".join(fmt_s(c_.get(c, {}).get("median")) for c in ["short", "medium", "long"])
        ratio = ""
        if gpu_run and cpu_run:
            gov = aggregate_overall(gpu_run["data"], "total_query_ms").get("median")
            cov = aggregate_overall(cpu_run["data"], "total_query_ms").get("median")
            if gov is not None and cov is not None and gov > 0:
                ratio = f"{cov / gov:.2f}×"
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | {doc_chars} | {gpu_cells} | {cpu_cells} | {ratio} |")
    md.append("")

    md.append("### TTFT (ms, median)\n")
    md.append("| k | doc_chars med | GPU TTFT | CPU TTFT | CPU÷GPU |")
    md.append("|---:|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get((model, "GPU", k))
        cpu_run = matrix.get((model, "CPU", k))
        if not gpu_run and not cpu_run:
            continue
        doc_chars = median_doc_chars(gpu_run["data"] if gpu_run else cpu_run["data"])
        gv = aggregate_overall(gpu_run["data"], "ttft_ms").get("median") if gpu_run else None
        cv = aggregate_overall(cpu_run["data"], "ttft_ms").get("median") if cpu_run else None
        ratio = f"{cv / gv:.1f}×" if (gv is not None and cv is not None and gv > 0) else ""
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | {doc_chars} | {fmt_ms(gv)} | {fmt_ms(cv)} | {ratio} |")
    md.append("")

    md.append("### Decode (ms, median)\n")
    md.append("| k | GPU decode | CPU decode | CPU÷GPU |")
    md.append("|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get((model, "GPU", k))
        cpu_run = matrix.get((model, "CPU", k))
        if not gpu_run and not cpu_run:
            continue
        gv = aggregate_overall(gpu_run["data"], "decode_ms").get("median") if gpu_run else None
        cv = aggregate_overall(cpu_run["data"], "decode_ms").get("median") if cpu_run else None
        ratio = f"{cv / gv:.2f}×" if (gv is not None and cv is not None and gv > 0) else ""
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | {fmt_ms(gv)} | {fmt_ms(cv)} | {ratio} |")
    md.append("")

    md.append("### p95 total query latency (s)\n")
    md.append("| k | GPU p95 | CPU p95 |")
    md.append("|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get((model, "GPU", k))
        cpu_run = matrix.get((model, "CPU", k))
        if not gpu_run and not cpu_run:
            continue
        gv = aggregate_overall(gpu_run["data"], "total_query_ms").get("p95") if gpu_run else None
        cv = aggregate_overall(cpu_run["data"], "total_query_ms").get("p95") if cpu_run else None
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | {fmt_s(gv)} | {fmt_s(cv)} |")
    md.append("")

    md.append("### Errors (count / 54 runs)\n")
    md.append("| k | GPU errors | CPU errors |")
    md.append("|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get((model, "GPU", k))
        cpu_run = matrix.get((model, "CPU", k))
        if not gpu_run and not cpu_run:
            continue
        ge = sum(1 for r in gpu_run["data"]["results"] if r.get("error")) if gpu_run else None
        ce = sum(1 for r in cpu_run["data"]["results"] if r.get("error")) if cpu_run else None
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | {fmt_ms(ge)} | {fmt_ms(ce)} |")
    md.append("")

    md.append("### Wall-clock\n")
    md.append("| k | GPU wall (min) | CPU wall (min) | CPU÷GPU |")
    md.append("|---:|---:|---:|---:|")
    for k in all_ks:
        gpu_run = matrix.get((model, "GPU", k))
        cpu_run = matrix.get((model, "CPU", k))
        if not gpu_run and not cpu_run:
            continue
        gw = gpu_run["data"]["total_benchmark_time_ms"] / 60000 if gpu_run else None
        cw = cpu_run["data"]["total_benchmark_time_ms"] / 60000 if cpu_run else None
        gw_s = f"{gw:.1f}" if gw is not None else "—"
        cw_s = f"{cw:.1f}" if cw is not None else "—"
        ratio = f"{cw / gw:.2f}×" if (gw is not None and cw is not None and gw > 0) else ""
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | {gw_s} | {cw_s} | {ratio} |")
    md.append("")


def _write_cross_model_table(
    md: list[str],
    matrix: dict,
    baseline_model: str,
    other_model: str,
    all_ks: list[int],
    metric: str,
    fmt: callable,
) -> None:
    """Emit one E4B-vs-E2B comparison table for the given metric.

    Layout: `| k | E4B GPU | E2B GPU | GPU ratio | E4B CPU | E2B CPU | CPU ratio |`.
    Ratio is baseline÷other (so >1 means the other model is faster).
    """
    b_label = _short_model_label(baseline_model)
    o_label = _short_model_label(other_model)
    md.append(
        f"| k | {b_label} GPU | {o_label} GPU | GPU ratio | "
        f"{b_label} CPU | {o_label} CPU | CPU ratio |"
    )
    md.append("|---:|---:|---:|---:|---:|---:|---:|")
    for k in all_ks:
        cells = []
        for backend in ("GPU", "CPU"):
            base_run = matrix.get((baseline_model, backend, k))
            other_run = matrix.get((other_model, backend, k))
            base_v = aggregate_overall(base_run["data"], metric).get("median") if base_run else None
            other_v = aggregate_overall(other_run["data"], metric).get("median") if other_run else None
            ratio = ""
            if base_v is not None and other_v is not None and other_v > 0:
                ratio = f"{base_v / other_v:.2f}×"
            cells.extend([fmt(base_v), fmt(other_v), ratio])
        k_label = "**0 (no-RAG)**" if k == 0 else str(k)
        md.append(f"| {k_label} | " + " | ".join(cells) + " |")
    md.append("")


def write_report(runs: list[dict], out_path: Path) -> None:
    # Build {(model, backend, k) -> latest canonical run}. If two runs collide
    # on the same key (e.g. a re-run on the same day), keep the one with the
    # most successful entries — that's almost always the longer, cleaner sweep.
    matrix: dict[tuple[str, str, int], dict] = {}
    for r in runs:
        key = (r["model"], r["backend"], r["k"])
        if key in matrix:
            ex = matrix[key]
            ex_ok = sum(1 for x in ex["data"]["results"] if not x.get("error"))
            r_ok = sum(1 for x in r["data"]["results"] if not x.get("error"))
            if r_ok > ex_ok:
                matrix[key] = r
        else:
            matrix[key] = r

    if not matrix:
        # latency_results/ is gitignored, so a fresh checkout can hit this. Exit
        # with a directional error rather than crashing on StopIteration below.
        results_dir = Path(__file__).resolve().parent / "latency_results"
        raise SystemExit(
            f"No canonical benchmark_*.json found under {results_dir}. "
            "Run `python evaluation/benchmark_latency.py …` to produce JSONs "
            "(see evaluation/runbooks/ for the sweep procedure), then re-run "
            "this aggregator."
        )

    models = sorted(set(m for (m, _b, _k) in matrix.keys()))
    all_ks = sorted(set(k for (_m, _b, k) in matrix.keys()))

    sample = next(iter(matrix.values()))
    dev = sample["data"]["device"]

    md: list[str] = []
    md.append("# MAM-AI On-Device Latency Sweep — Model × Backend × k\n")
    md.append(f"_Generated: {datetime.datetime.now().isoformat(timespec='seconds')}_\n")
    md.append("")
    md.append("## Device & stack\n")
    md.append(f"- **Device**: {dev.get('manufacturer', '?')} {dev.get('model', '?')} ({dev.get('soc', '?')}) — Android {dev.get('android_version', '?')}")
    md.append(f"- **Models tested**: " + ", ".join(f"{_short_model_label(m)} (`{m}`)" for m in models))
    md.append("- **LiteRT-LM**: 0.11.0")
    md.append("- **Backends tested**: GPU (OpenCL, via `useGpuForLlm=true`) and CPU")
    md.append("- **Sampling**: temp=1.0, top_p=0.95, top_k=64, max_tokens=32000")
    md.append("")
    sample_cfg = sample["data"].get("config", {})
    sample_repeats = sample_cfg.get("repeats", "?")
    sample_cooldown_s = (sample_cfg.get("cooldown_ms") or 0) / 1000.0
    sample_n_results = len(sample["data"]["results"])
    queries_x_modes: object = "?"
    if isinstance(sample_repeats, int) and sample_repeats > 0 and sample_n_results % sample_repeats == 0:
        queries_x_modes = sample_n_results // sample_repeats
    md.append("## Methodology\n")
    md.append(
        f"Per (model × backend × k) configuration: {queries_x_modes} (query × mode) cells "
        f"× {sample_repeats} repeats = {sample_n_results} timed runs. Plus a "
        f"No-RAG baseline per (model × backend) (k=0 via `--no-retrieval`). "
        f"{sample_cooldown_s:g}-second cooldown between runs for thermal "
        "stability. Activity → ForegroundService with PARTIAL_WAKE_LOCK so "
        "the run survives screen-off and device-lock; OPPO Hans whitelist set "
        "manually."
    )
    md.append("")
    md.append("- `TTFT` excludes retrieval — measured from end-of-retrieval to first generated token.")
    md.append("- `decode` is first-token to last-token.")
    md.append("- `total_query` is everything: `retrieval + TTFT + decode`.")
    md.append(f"- Reported as median across the {sample_n_results} runs unless noted (p95 in tables marked `p95`).")
    md.append("")

    # ─────────── Per-model sections ───────────
    for m in models:
        _write_per_model_section(md, matrix, m, all_ks)

    # ─────────── Cross-model comparison ───────────
    # Use E4B as baseline when present; ratio is baseline/other so >1 means
    # the (smaller) comparator model is faster on that cell.
    if len(models) > 1:
        baseline = "gemma-4-E4B-it.litertlm" if "gemma-4-E4B-it.litertlm" in models else models[0]
        others = [m for m in models if m != baseline]
        others_label = ", ".join(_short_model_label(m) for m in others)
        md.append("## Cross-model comparison\n")
        md.append(
            f"Each table below compares **{_short_model_label(baseline)}** "
            f"(baseline) against each comparator model ({others_label}). "
            "Ratios are reported as **baseline ÷ comparator** at the same "
            "backend × k cell, so values **> 1.0× mean the comparator is faster**. "
            "Reading the columns: GPU prefill (TTFT) is compute-bound and tracks "
            "parameter count closely; GPU decode is bandwidth-bound and gains less "
            "from model shrinkage; CPU is compute-bound throughout."
        )
        md.append("")
        for other in others:
            md.append(f"### {_short_model_label(baseline)} vs {_short_model_label(other)}")
            md.append("")
            md.append("**Total query latency (median, seconds)**")
            md.append("")
            _write_cross_model_table(md, matrix, baseline, other, all_ks, "total_query_ms", fmt_s)
            md.append("**TTFT (median, ms)** — prefill speedup")
            md.append("")
            _write_cross_model_table(md, matrix, baseline, other, all_ks, "ttft_ms", fmt_ms)
            md.append("**Decode (median, ms)** — bandwidth-limited on GPU, compute-limited on CPU")
            md.append("")
            _write_cross_model_table(md, matrix, baseline, other, all_ks, "decode_ms", fmt_ms)

    md.append("## Errors and the 4096-token context wall\n")
    md.append("At k=20, the **same 8 queries × 3 reps = 24 runs** failed across every "
              "(model × backend) combination tested: ")
    md.append("`long_01, long_03, medium_02, medium_04, short_01, short_03, short_04, short_05`. ")
    md.append("Each failure reports `Input token ids are too long. Exceeding the maximum "
              "number of tokens allowed: …>= 4096`. The cap is enforced by LiteRT-LM's "
              "native runtime (verified by extracting `liblitertlm_jni.so` from the AAR "
              "and locating the literal error template).")
    md.append("")
    md.append("### Where the 4096 comes from — and why we set it explicitly\n")
    md.append("The Kotlin `EngineConfig` constructor exposes a `maxNumTokens` parameter; "
              "leaving it `null` falls back to whatever the engine's default is for the "
              "loaded artifact. The original `RagPipeline.kt` left it null, so the 4096 "
              "ceiling was an inferred property of *somewhere* in the stack rather than a "
              "stated choice. **A 2026-05-16 experiment on the test device pinned this "
              "down** — see commit log for `feat/explicit-max-num-tokens`:")
    md.append("")
    md.append("- **Lower-bound test (`maxNumTokens = 2048`)**: queries with prompts "
              "between 2048–4096 tokens that previously succeeded now fail, with the "
              "error message reporting the new ceiling verbatim (`>= 2048`). Both GPU "
              "and CPU clamp identically. **The knob is wired through to the native "
              "runtime as-advertised.**")
    md.append("- **Upper-bound test (`maxNumTokens = 8192`)**: `Engine.initialize()` "
              "succeeds on both backends; the artifact is *not* hard-bounded at 4096. "
              "Previously-failing k=20 queries now run end-to-end on both backends. "
              "**However:** on CPU the output stays coherent (real medical reasoning, "
              "ends with reference numbers); on GPU the output degenerates into a long "
              "repetition loop (`*   *   *   *   ...`) past the 4096-token mark. "
              "Same artifact, same query — output diverges by backend at lifted context.")
    md.append("")
    md.append("**Operational conclusion:** 4096 is the highest value that produces clean "
              "generations across both backends for this artifact family, and is "
              "therefore the right value to ship. `RagPipeline.kt:buildEngine()` now "
              "passes it explicitly so the ceiling is visible at the call site rather "
              "than left implicit. **k_max ≈ 17–18** for both models — a deployment "
              "ceiling driven by output quality on GPU, not by a runtime hard cap.")
    md.append("")

    md.append("## Key findings\n")
    md.append("### 1. Prefill (TTFT) scales ~2× with parameter count on both backends")
    md.append("Halving the parameter count (E4B → E2B) gives a **consistent ~2.3× TTFT speedup on GPU** "
              "and **~2.3–3.2× on CPU**. Prefill is compute-heavy (one parallel forward pass over the "
              "entire prompt), so halving the parameter count halves the compute and the speedup is "
              "near-proportional on both backends.")
    md.append("")
    md.append("### 2. Decode is bandwidth-bound on GPU, compute-bound on CPU")
    md.append("Decode speedup from E4B → E2B is **~1.5× on GPU** but **~2× on CPU**. Decode is "
              "sequential (one token at a time), so on GPU it's limited by memory bandwidth feeding "
              "weights into compute units — the smaller model helps less than its parameter count "
              "would predict. On CPU the constraint is compute, so the speedup tracks the model shrink.")
    md.append("")
    md.append("### 3. Total speedup is decode-dominated, hence smaller than TTFT")
    md.append("**Total-query speedup**: ~1.5× GPU, ~2.2× CPU. Total = TTFT + decode + retrieval; since "
              "decode dominates total at low-to-mid k (TTFT is small there), the total speedup tracks "
              "decode rather than prefill. At high k where prefill grows large, total speedup climbs "
              "toward the prefill ratio (~1.7–1.9× GPU at k=15+).")
    md.append("")
    md.append("### 4. GPU still wins, but E2B CPU opens up the no-GPU device tier")
    md.append("E2B CPU is 1.4–2.4× slower than E2B GPU at every k — GPU remains the preferred backend "
              "where available. But E2B CPU at k=1 (~16 s median) is comparable to E4B GPU at k=1 (~14 s), "
              "which means devices that previously could *not* deploy MAM-AI at acceptable latency "
              "(mid-tier MediaTek, older Snapdragon without OpenCL) now have a realistic path: "
              "ship E2B on CPU, restrict k to small values.")
    md.append("")
    md.append("### 5. 4096-token context wall is the binding ceiling at high k — and the right one")
    md.append("k=15 works cleanly on all four (model × backend) combinations. k=20 fails identically "
              "across all four: same 8 queries, same 24 (query × rep) failures, same `>= 4096` "
              "error. Phase B/C experiments on 2026-05-16 (see §context wall above) show the cap "
              "is **liftable** — passing `maxNumTokens = 8192` makes the runtime accept larger "
              "prompts — but the lift produces **quality degradation on GPU** (response loops "
              "into repetition past 4096 tokens) while CPU output stays clean. 4096 is therefore "
              "the right deployment ceiling for cross-backend safety, not just a memory or "
              "runtime constraint. **Latency is not the constraint at the upper end of k — "
              "output quality is.**")
    md.append("")
    md.append("### 6. TTFT scales linearly with retrieved-doc content past k=3")
    md.append("On both backends and both models, TTFT-per-doc-char is roughly constant past k=3, so "
              "the prefill story scales predictably. The model shrink translates directly into a TTFT "
              "shrink across the whole range.")
    md.append("")

    # File inventory
    md.append("## Data inventory (per `(model, backend, k)`)\n")
    md.append("| Model | Backend | k | File | Wall (min) | Runs | Errors |")
    md.append("|---|---|---:|---|---:|---:|---:|")
    for (m, b, k) in sorted(matrix.keys(), key=lambda x: (x[0], x[1], x[2])):
        r = matrix[(m, b, k)]
        wall = r["data"]["total_benchmark_time_ms"] / 60000
        n = len(r["data"]["results"])
        e = sum(1 for x in r["data"]["results"] if x.get("error"))
        k_label = "0 (no-RAG)" if k == 0 else str(k)
        md.append(f"| {_short_model_label(m)} | {b} | {k_label} | `{r['file']}` | {wall:.1f} | {n} | {e} |")
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
    models = sorted(set(r["model"] for r in runs))
    print(f"Loaded {len(runs)} canonical runs across {len(models)} models: {', '.join(models)}")
    out = Path(__file__).resolve().parent / "reports" / "latency_report_v2.md"
    write_report(runs, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
