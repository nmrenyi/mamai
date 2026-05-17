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

    # Errors per (model × backend × k) are uniform: 0 everywhere except k=20=24.
    # Don't waste a table per model on the same finding — the FP16-vs-FP32 GPU
    # section discusses errors in prose, and the data inventory below records
    # per-run error counts. Per-model error tables removed 2026-05-17.

    # Wall-clock (benchmark runtime, not user-facing UX latency) is an
    # operational metric — moved to the Appendix at the bottom of the report.


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

    # Order: production-deployed model first (currently E4B), then others
    # alphabetically. Keeps per-model sections + the cross-model comparison
    # baseline consistent.
    def _model_priority(m: str) -> tuple[int, str]:
        if m == "gemma-4-E4B-it.litertlm":
            return (0, m)
        return (1, m)
    models = sorted(set(m for (m, _b, _k) in matrix.keys()), key=_model_priority)
    all_ks = sorted(set(k for (_m, _b, k) in matrix.keys()))

    sample = next(iter(matrix.values()))
    dev = sample["data"]["device"]

    md: list[str] = []
    md.append("# MAM-AI On-Device Latency Sweep — Model × Backend × k\n")
    md.append(f"_Generated: {datetime.datetime.now().isoformat(timespec='seconds')}_\n")
    md.append("")
    md.append("## Device & stack\n")
    soc = dev.get('soc', '?')
    soc_display = f"{soc} / Snapdragon 8 Elite" if soc == "SM8750P" else soc
    md.append(f"- **Device**: {dev.get('manufacturer', '?')} {dev.get('model', '?')} ({soc_display}) — Android {dev.get('android_version', '?')}, 16 GB RAM")
    md.append(f"- **Models tested**: " + ", ".join(f"{_short_model_label(m)} (`{m}`)" for m in models))
    md.append("- **LiteRT-LM**: 0.11.0")
    md.append("- **Backends tested**: GPU (OpenCL on Adreno) and CPU (XNNPACK)")
    md.append("- **Activation precision**: GPU defaults to **FP16**, CPU defaults to **FP32** — this asymmetry matters at lifted context (see [`maxnumtoken_investigation.md`](maxnumtoken_investigation.md) §Step 4). All measurement tables use the defaults; one explicit FP32-on-GPU sweep is summarised in the FP16-vs-FP32 GPU section below.")
    md.append("- **Sampling**: temp=1.0, top_p=0.95, top_k=64 — read from `runtime_config.json`. No explicit `max_output_tokens` cap is enforced; the runtime decodes until a stop token or until total context hits `maxNumTokens=4096`.")
    md.append("- **Total context budget** (`maxNumTokens` passed to `EngineConfig`): **4096** for every measurement table in this report. The FP16/FP32 section's prose discusses lifted values (5000, 8192) used purely to characterize the cliff — those measurements are not in any table.")
    md.append("")
    md.append("## TL;DR — today's deployment")
    md.append("")
    md.append("> **Ship configuration: FP16 GPU running Gemma 4 E4B at `maxNumTokens=4096` on Snapdragon 8 Elite.** Median total query latency **13–25 s across k=0–15 for E4B** (7.9–18 s for the smaller E2B); cleanly below the FP16 quality cliff at total context ~5000.")
    md.append(">")
    md.append("> k=20 is **partial**: the 8 longest of 18 query types produce prompts >4096 tokens and get runtime-rejected (24/54 errors in every sweep); the other 10 query types complete normally.")
    md.append(">")
    md.append("> Fallbacks: **FP32 GPU at max=4096** (~21–34% slower at k=10–15, no precision cliff) for extra correctness margin on the same hardware; **FP32 GPU at max=5000–6000** for higher context (verified on this 16 GB device; max=8192 OOMs because FP32 doubles the KV cache, so the practical ceiling is around 6500–7500); **CPU FP32** (~2–4× slower than FP16 GPU) for devices without working OpenCL.")
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
    md.append("### Provenance fields in benchmark JSONs (post-`52e11e9`)\n")
    md.append("Each benchmark JSON's `config` block records `max_num_tokens`, `artifact_fingerprint` (SHA-256 of first 64 KB of the loaded `.litertlm`), and `git_commit_sha`. Together these let any reviewer cryptographically verify which artifact variant + code state produced the JSON, without trusting the filename. Earlier sweep JSONs (PR #57/#59) lack these fields but their content is unaffected.")
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
        comparator_phrase = f"the comparator ({others_label})" if len(others) == 1 else f"each comparator ({others_label})"
        md.append(
            f"Each table below compares **{_short_model_label(baseline)}** "
            f"(baseline) against {comparator_phrase}. Ratios are reported as "
            "**baseline ÷ comparator** at the same backend × k cell, so values "
            "**> 1.0× mean the comparator is faster**. The architectural "
            "story behind these ratios (prefill compute-bound vs decode "
            "bandwidth-bound) is in Key findings #1–#2 below."
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

    md.append("## FP16 vs FP32 GPU (and why the context cap is 4096)")
    md.append("")
    md.append("All cross-model tables above use the **default** GPU activation precision, which on Android is **FP16**. That choice is not a knob in our code — LiteRT-LM picks FP16 for the GPU text-decoder path and FP32 for CPU (XNNPACK). The 4096 `maxNumTokens` value we ship was chosen because of how the two precisions behave at lifted context; the full investigation is in [`maxnumtoken_investigation.md`](maxnumtoken_investigation.md). Headlines:")
    md.append("")
    md.append("- **The 4096 cap is a runtime config check, not an architectural constant.** It's `maxNumTokens` in `EngineConfig`, sourced from `runtime_config.json`. When the prompt alone exceeds it, LiteRT-LM rejects the request before any decoding starts (verified in `liblitertlm_jni.so`). At k=20, the same 8 of 18 query types in every sweep produce prompts above 4096 and get rejected — that's the 24/54 errors visible in every k=20 cell across all (model × backend) combinations.")
    md.append("- ⚠️ **The FP16 default has a quality cliff** at total context ~5000 tokens. If you lift the cap to admit larger prompts, GPU output silently collapses into a `*` repetition loop, deterministically. Concrete example: [`benchmark_20260516T104730_k20.json`](../latency_results/benchmark_20260516T104730_k20.json) (long_01, k=20, FP16 GPU, maxNumTokens=8192).")
    md.append("- **CPU (FP32) stays clean** for the same lifted-cap prompt — the asymmetry isolates precision as the cause, not the artifact or backend choice.")
    md.append("- **Confirming the fix**: forcing GPU to FP32 (via injecting `prefer_activation_type=float32` into the `.litertlm` metadata) eliminates the cliff. Direct A/B on the exact `long_01` k=20 case wasn't possible — FP32 KV cache at maxNumTokens=8192 OOMs the test device — but the closest-comparable test (`long_01` k=15, max=5000, response ending at total context ~4514) produced clean output through the same FP16-cliff zone.")
    md.append("- **Our 4096 ship value gives ~900 tokens of safety margin** below the FP16 cliff. Anyone lifting the cap on FP16 GPU enters the silent-failure zone; switch to FP32 GPU first.")
    md.append("")
    md.append("### Latency cost of FP32 on GPU (E4B at maxNumTokens=4096, 2026-05-17)")
    md.append("")
    md.append("Apples-to-apples sweep with `artifact_fingerprint`-verified provenance. Full 8×2 table is in the investigation doc §Step 6; the medians at a representative subset:")
    md.append("")
    md.append("| k | FP16 GPU total | FP32 GPU total | T ratio | FP16 TTFT | FP32 TTFT | TTFT ratio | FP16 decode | FP32 decode |")
    md.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    md.append("| **0 (no-RAG)** | 14.5 s | 16.5 s | 1.14× | 0.97 s | 2.03 s | 2.10× | 13.5 s | 14.4 s |")
    md.append("| 1 | 14.1 s | 18.0 s | 1.28× | 0.95 s | 2.06 s | 2.16× | 11.4 s | 12.8 s |")
    md.append("| 5 | 19.6 s | 24.3 s | 1.24× | 1.88 s | 4.28 s | 2.28× | 16.0 s | 16.3 s |")
    md.append("| 10 | 22.6 s | 27.4 s | 1.21× | 2.53 s | 5.85 s | 2.32× | 18.2 s | 18.6 s |")
    md.append("| 15 | 23.1 s | 30.9 s | 1.34× | 3.45 s | 8.37 s | 2.43× | 16.9 s | 18.4 s |")
    md.append("")
    md.append("Two clean stories:")
    md.append("")
    md.append("- **Prefill (TTFT) is ~2.1–2.5× slower on FP32** — prefill is compute-bound, and FP16 doubles arithmetic throughput on Adreno. The ratio is stable across k.")
    md.append("- **Decode is essentially identical** (within ~9% on every cell) — decode is bandwidth-bound, so precision barely matters in steady-state generation.")
    md.append("- **Total query is 6–34% slower on FP32**, depending on how much of total is prefill vs decode at the given k. At our typical k=10–15 cells, ~21–34% slower (~5–8 s extra wait per query).")
    md.append("")
    md.append("### When to ship FP32 GPU instead of FP16 GPU")
    md.append("")
    md.append("| Use case | Choice | Why |")
    md.append("|---|---|---|")
    md.append("| **Today's deployment** | FP16 GPU, max=4096 | Clean output below the cliff; fastest UX |")
    md.append("| Extra correctness margin without changing context | FP32 GPU, max=4096 | ~25% slower at k=15 but eliminates the FP16 cliff as a risk class entirely |")
    md.append("| Higher context (e.g., k>15 desired in future) | FP32 GPU, max=5000–6000 | No cliff. Memory: KV cache doubles → ~6500–7500 ceiling on 16 GB devices |")
    md.append("| GPU unavailable (MediaTek / older Snapdragon) | CPU FP32 | Always clean, but ~2–4× slower than FP16 GPU |")
    md.append("")
    md.append("---")
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
              "decode rather than prefill. The GPU total ratio peaks at k=15 (~1.86×) where prefill is "
              "a larger fraction of the budget, then drops back at k=20 (~1.28×) — but the k=20 cell "
              "is a **survivor-bias artifact**: 24 of 54 queries error on the prompt-cap check (the "
              "8 longest queries × 3 reps), so the k=20 median is computed over the 30 *shorter* "
              "queries that happen to fit. The trend is not a real reversal.")
    md.append("")
    md.append("### 4. GPU still wins, but E2B CPU opens up the no-GPU device tier")
    md.append("E2B CPU is 1.4–2.4× slower than E2B GPU at every k — GPU remains the preferred backend "
              "where available. But E2B CPU at k=1 (~16 s median) is comparable to E4B GPU at k=1 (~14 s), "
              "which means devices that previously could *not* deploy MAM-AI at acceptable latency "
              "(mid-tier MediaTek, older Snapdragon without OpenCL) now have a realistic path: "
              "ship E2B on CPU, restrict k to small values.")
    md.append("")
    md.append("### 5. The 4096-token cap is a precision-driven safety margin, not a hard runtime limit")
    md.append("k=15 works cleanly on every (model × backend) cell. At k=20, the 8 longest of 18 query "
              "types exceed the cap and get rejected by the runtime (24/54 errors per cell, identical "
              "across all backends). The cap itself is *liftable* — but on the default **FP16** GPU "
              "path, lifted output silently collapses past total context ~5000. FP32 GPU removes the "
              "cliff at ~25% latency cost. See the FP16-vs-FP32 GPU section above for details. "
              "**The constraint at high k is precision, not latency or memory.**")
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
    for (m, b, k) in sorted(matrix.keys(), key=lambda x: (_model_priority(x[0]), x[1], x[2])):
        r = matrix[(m, b, k)]
        wall = r["data"]["total_benchmark_time_ms"] / 60000
        n = len(r["data"]["results"])
        e = sum(1 for x in r["data"]["results"] if x.get("error"))
        k_label = "0 (no-RAG)" if k == 0 else str(k)
        md.append(f"| {_short_model_label(m)} | {b} | {k_label} | `{r['file']}` | {wall:.1f} | {n} | {e} |")
    md.append("")
    md.append("> **Note:** the table above lists the canonical FP16-default runs (which is what every table in this report tabulates). The `Wall (min)` column is benchmark runtime (operational), not user-facing latency. The aggregator dedupes by `(model, backend, k)`, so the **8 FP32 GPU sweep JSONs (2026-05-16)** and the **16 today-instrumented runs (2026-05-17, FP32 + FP16 with `artifact_fingerprint` provenance)** referenced by the FP16-vs-FP32 GPU section are not listed here. Their full filenames + fingerprints are in [`maxnumtoken_investigation.md`](maxnumtoken_investigation.md) §References.")
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
