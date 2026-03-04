#!/usr/bin/env python3
"""
On-device latency benchmark for MAM-AI.

Drives BenchmarkActivity via ADB, pulls results from the device,
computes statistics, and generates a markdown report.

Usage:
    python evaluation/benchmark_latency.py                          # Default: 3 repeats, all queries
    python evaluation/benchmark_latency.py --repeats 5              # More repeats for tighter stats
    python evaluation/benchmark_latency.py --filter short           # Only short queries
    python evaluation/benchmark_latency.py --filter long_01         # Single specific query
    python evaluation/benchmark_latency.py --no-retrieval           # Skip RAG retrieval
    python evaluation/benchmark_latency.py --cooldown 10000         # Longer cooldown (thermal)
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime

PACKAGE = "com.example.app"
ACTIVITY = f"{PACKAGE}/.BenchmarkActivity"
RESULT_PATH_ON_DEVICE = f"/storage/emulated/0/Android/data/{PACKAGE}/files/benchmark_results.json"
BENCHMARK_COMPLETE_MARKER = "[BENCHMARK] COMPLETE"
BENCHMARK_FAILED_MARKER = "[BENCHMARK] FAILED"
LOG_TAG = "mam-ai-bench"


# ── ADB helpers ───────────────────────────────────────────────────────────

def _adb(device_serial=None):
    """Build base ADB command with optional device serial."""
    cmd = ["adb"]
    if device_serial:
        cmd += ["-s", device_serial]
    return cmd


def check_device(device_serial=None):
    """Verify a device is connected and the app is installed."""
    result = subprocess.run(
        _adb(device_serial) + ["devices"], capture_output=True, text=True
    )
    lines = [
        l
        for l in result.stdout.strip().split("\n")[1:]
        if l.strip() and "device" in l
    ]
    if not lines:
        print("ERROR: No Android device connected.")
        sys.exit(1)

    result = subprocess.run(
        _adb(device_serial) + ["shell", "pm", "list", "packages", PACKAGE],
        capture_output=True,
        text=True,
    )
    if PACKAGE not in result.stdout:
        print(f"ERROR: {PACKAGE} is not installed on the device.")
        print("Build and install the app first: cd app && flutter build apk && flutter install")
        sys.exit(1)
    print("Device connected, app installed.")


def check_models_downloaded(device_serial=None):
    """Check if model files exist on device."""
    required_files = [
        "gemma-3n-E4B-it-int4.task",
        "Gecko_1024_quant.tflite",
        "sentencepiece.model",
        "embeddings.sqlite",
    ]
    base = f"/storage/emulated/0/Android/data/{PACKAGE}/files"
    for f in required_files:
        result = subprocess.run(
            _adb(device_serial) + ["shell", "ls", f"{base}/{f}"],
            capture_output=True,
            text=True,
        )
        if "No such file" in result.stderr or result.returncode != 0:
            print(f"ERROR: Model file not found on device: {f}")
            print("Launch the app normally first to download model files.")
            sys.exit(1)
    print("All model files present on device.")


def force_stop_app(device_serial=None):
    """Force stop the app to ensure clean state."""
    subprocess.run(
        _adb(device_serial) + ["shell", "am", "force-stop", PACKAGE],
        capture_output=True,
    )


def clear_logcat(device_serial=None):
    """Clear logcat buffer."""
    subprocess.run(_adb(device_serial) + ["logcat", "-c"], capture_output=True)


def launch_benchmark(device_serial=None, repeats=3, cooldown_ms=5000,
                     skip_retrieval=False, query_filter=None):
    """Launch BenchmarkActivity via ADB."""
    cmd = _adb(device_serial) + [
        "shell", "am", "start",
        "-n", ACTIVITY,
        "--ei", "repeats", str(repeats),
        "--el", "cooldown_ms", str(cooldown_ms),
    ]
    if skip_retrieval:
        cmd += ["--ez", "skip_retrieval", "true"]
    if query_filter:
        cmd += ["--es", "query_filter", query_filter]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if "Error" in result.stderr:
        print(f"ERROR: Failed to launch benchmark: {result.stderr}")
        sys.exit(1)
    print("Benchmark launched. Monitoring logcat for progress...")


def wait_for_completion(device_serial=None, timeout_s=3600):
    """Monitor logcat for the COMPLETE or FAILED marker."""
    cmd = _adb(device_serial) + [
        "logcat", "-s", f"{LOG_TAG}:W", "--format", "brief",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    start = time.time()
    try:
        for line in proc.stdout:
            line = line.strip()
            if "[BENCHMARK]" in line:
                print(f"  {line}")
            if BENCHMARK_COMPLETE_MARKER in line:
                proc.terminate()
                return True
            if BENCHMARK_FAILED_MARKER in line:
                proc.terminate()
                return False
            if time.time() - start > timeout_s:
                proc.terminate()
                print(f"ERROR: Benchmark timed out after {timeout_s}s")
                return False
    except KeyboardInterrupt:
        proc.terminate()
        print("\nBenchmark interrupted by user.")
        return False

    proc.terminate()
    return False


def pull_results(device_serial=None, local_path="benchmark_results.json"):
    """Pull results JSON from device."""
    cmd = _adb(device_serial) + ["pull", RESULT_PATH_ON_DEVICE, local_path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: Failed to pull results: {result.stderr}")
        sys.exit(1)
    print(f"Results pulled to {local_path}")


# ── Statistics ────────────────────────────────────────────────────────────

def compute_statistics(values):
    """Compute mean, median, std, p5, p95, min, max for a list of numbers."""
    if not values:
        return {}
    n = len(values)
    s = sorted(values)
    mean = statistics.mean(values)
    median = statistics.median(values)
    std = statistics.stdev(values) if n > 1 else 0.0
    p5 = s[max(0, int(n * 0.05))]
    p95 = s[min(n - 1, int(n * 0.95))]
    return {
        "n": n,
        "mean": round(mean, 1),
        "median": round(median, 1),
        "std": round(std, 1),
        "min": round(min(values), 1),
        "max": round(max(values), 1),
        "p5": round(p5, 1),
        "p95": round(p95, 1),
    }


def analyze_results(data):
    """Compute per-category and overall statistics from benchmark results."""
    results = data["results"]

    # Group by (category, use_retrieval)
    groups = {}
    for r in results:
        if r.get("error") and r["error"] is not None:
            continue
        key = (r["category"], r["use_retrieval"])
        groups.setdefault(key, []).append(r)

    analysis = {}
    for (category, use_retrieval), entries in sorted(groups.items()):
        label = f"{category}_{'rag' if use_retrieval else 'no_rag'}"
        analysis[label] = {
            "category": category,
            "use_retrieval": use_retrieval,
            "n_queries": len(set(e["query_id"] for e in entries)),
            "n_runs": len(entries),
            "ttft_ms": compute_statistics([e["ttft_ms"] for e in entries]),
            "prefill_ms": compute_statistics([e["prefill_ms"] for e in entries]),
            "decode_ms": compute_statistics([e["decode_ms"] for e in entries]),
            "retrieval_time_ms": compute_statistics(
                [e["retrieval_time_ms"] for e in entries if e["retrieval_time_ms"] > 0]
            ),
            "total_query_ms": compute_statistics([e["total_query_ms"] for e in entries]),
            "response_length_chars": compute_statistics(
                [e["response_length_chars"] for e in entries]
            ),
            "estimated_tokens": compute_statistics([e["estimated_tokens"] for e in entries]),
            "decode_throughput_tps": compute_statistics(
                [e["decode_throughput_tps"] for e in entries if e["decode_throughput_tps"] > 0]
            ),
            "heap_after_mb": compute_statistics([e["heap_after_mb"] for e in entries]),
        }

    # Overall statistics
    all_entries = [r for r in results if not r.get("error") or r["error"] is None]
    if all_entries:
        analysis["overall"] = {
            "n_runs": len(all_entries),
            "n_errors": sum(1 for r in results if r.get("error") and r["error"] is not None),
            "ttft_ms": compute_statistics([e["ttft_ms"] for e in all_entries]),
            "decode_ms": compute_statistics([e["decode_ms"] for e in all_entries]),
            "total_query_ms": compute_statistics([e["total_query_ms"] for e in all_entries]),
            "decode_throughput_tps": compute_statistics(
                [e["decode_throughput_tps"] for e in all_entries if e["decode_throughput_tps"] > 0]
            ),
        }

    return analysis


# ── Report generation ─────────────────────────────────────────────────────

def _analyze_thermal_drift(results):
    """Check if performance degrades over time (sign of thermal throttling)."""
    valid = [r for r in results if (not r.get("error") or r["error"] is None) and r["total_query_ms"] > 0]
    if len(valid) < 6:
        return "Insufficient data points for thermal drift analysis."

    n = len(valid)
    third = n // 3
    first_third = [r["total_query_ms"] for r in valid[:third]]
    last_third = [r["total_query_ms"] for r in valid[-third:]]

    mean_first = statistics.mean(first_third)
    mean_last = statistics.mean(last_third)
    drift_pct = ((mean_last - mean_first) / mean_first) * 100

    msg = f"Mean total query time: first third = {mean_first:.0f}ms, last third = {mean_last:.0f}ms "
    if drift_pct > 15:
        msg += f"(**+{drift_pct:.0f}% degradation** -- thermal throttling likely)"
    elif drift_pct > 5:
        msg += f"(+{drift_pct:.0f}% increase -- mild thermal effect)"
    elif drift_pct < -5:
        msg += f"({drift_pct:.0f}% decrease -- possible warmup effect)"
    else:
        msg += f"({drift_pct:+.0f}% -- stable, no significant thermal effect)"
    return msg


def _fmt(stat, key="mean"):
    """Format a stat value, returning '-' if missing."""
    if not stat or key not in stat:
        return "-"
    return str(stat[key])


def generate_report(data, analysis, output_path):
    """Generate a markdown report from benchmark results and analysis."""
    device = data["device"]
    config = data["config"]
    init_data = data["init"]
    memory = data["memory"]
    timestamp = data["timestamp"]

    lines = []
    lines.append("# MAM-AI On-Device Latency Benchmark Report")
    lines.append("")
    lines.append(f"**Date**: {timestamp[:8]}")
    lines.append(f"**Device**: {device['manufacturer']} {device['model']} ({device.get('soc', 'unknown')} SoC)")
    lines.append(f"**Android**: {device['android_version']} (SDK {device['sdk_int']})")
    lines.append(f"**Model**: {config['model']} ({config['backend']} backend)")
    lines.append(f"**Repeats per query**: {config['repeats']}")
    lines.append(f"**Cooldown between queries**: {config['cooldown_ms']}ms")
    total_s = data["total_benchmark_time_ms"] / 1000
    lines.append(f"**Total benchmark time**: {total_s:.0f}s ({total_s / 60:.1f} min)")
    lines.append("")

    # 1. Initialization
    lines.append("## 1. Initialization")
    lines.append("")
    lines.append("| Metric | Time |")
    lines.append("|---|---|")
    lines.append(f"| Gecko + SQLite init | {init_data.get('gecko_sqlite_ms', init_data.get('sync_init_ms', '?'))}ms |")
    lines.append(f"| LLM model load | {init_data.get('llm_load_ms', init_data.get('llm_init_ms', '?'))}ms |")
    lines.append(f"| Warmup query | {init_data.get('warmup_query_ms', '?')}ms |")
    lines.append(f"| Total initialization | {init_data['total_init_ms']}ms |")
    lines.append("")

    # 2. Memory
    lines.append("## 2. Memory Usage (Post-Init)")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append(f"| Heap used | {memory['used_mb']}MB |")
    lines.append(f"| Heap free | {memory['free_mb']}MB |")
    lines.append(f"| Heap total | {memory['total_mb']}MB |")
    lines.append(f"| Heap max | {memory['max_mb']}MB |")
    lines.append("")

    # 3. Summary table
    lines.append("## 3. Summary")
    lines.append("")
    lines.append("| Category | Retrieval | TTFT (ms) | Decode (ms) | Total (ms) | Decode (tok/s) | Runs |")
    lines.append("|---|---|---|---|---|---|---|")
    for label, stats in sorted(analysis.items()):
        if label == "overall":
            continue
        retrieval_mode = "RAG" if stats["use_retrieval"] else "No RAG"
        lines.append(
            f"| {stats['category'].capitalize()} | {retrieval_mode} "
            f"| {_fmt(stats['ttft_ms'])} | {_fmt(stats['decode_ms'])} "
            f"| {_fmt(stats['total_query_ms'])} | {_fmt(stats['decode_throughput_tps'])} "
            f"| {stats['n_runs']} |"
        )
    lines.append("")

    # 4. Detailed per-category tables
    lines.append("## 4. Detailed Latency by Category")
    lines.append("")

    metric_rows = [
        ("ttft_ms", "TTFT (ms)"),
        ("decode_ms", "Decode (ms)"),
        ("total_query_ms", "Total query (ms)"),
        ("retrieval_time_ms", "Retrieval (ms)"),
        ("response_length_chars", "Response (chars)"),
        ("estimated_tokens", "Est. output tokens"),
        ("decode_throughput_tps", "Decode (tok/s)"),
    ]

    for label, stats in sorted(analysis.items()):
        if label == "overall":
            continue
        category = stats["category"]
        retrieval_mode = "With RAG" if stats["use_retrieval"] else "Without RAG"
        lines.append(f"### {category.capitalize()} Queries -- {retrieval_mode}")
        lines.append(f"*{stats['n_queries']} unique queries, {stats['n_runs']} total runs*")
        lines.append("")
        lines.append("| Metric | Mean | Median | Std | P95 | Min | Max |")
        lines.append("|---|---|---|---|---|---|---|")
        for metric_key, metric_label in metric_rows:
            s = stats.get(metric_key, {})
            if s and s.get("n", 0) > 0:
                lines.append(
                    f"| {metric_label} | {s['mean']} | {s['median']} "
                    f"| {s['std']} | {s['p95']} | {s['min']} | {s['max']} |"
                )
        lines.append("")

    # 5. Overall
    if "overall" in analysis:
        o = analysis["overall"]
        lines.append("## 5. Overall")
        lines.append("")
        lines.append(f"- **Total runs**: {o['n_runs']} ({o['n_errors']} errors)")
        lines.append(f"- **Mean TTFT**: {_fmt(o['ttft_ms'])}ms (P95: {_fmt(o['ttft_ms'], 'p95')}ms)")
        lines.append(f"- **Mean decode**: {_fmt(o['decode_ms'])}ms (P95: {_fmt(o['decode_ms'], 'p95')}ms)")
        lines.append(f"- **Mean total query**: {_fmt(o['total_query_ms'])}ms (P95: {_fmt(o['total_query_ms'], 'p95')}ms)")
        tps = o.get("decode_throughput_tps", {})
        if tps:
            lines.append(f"- **Mean decode throughput**: {_fmt(tps)} tok/s (P95: {_fmt(tps, 'p95')} tok/s)")
        lines.append("")

    # 6. Memory analysis
    lines.append("## 6. Memory Analysis")
    lines.append("")
    heap_entries = []
    for label, stats in sorted(analysis.items()):
        if label == "overall":
            continue
        s = stats.get("heap_after_mb", {})
        if s:
            heap_entries.append((label, s))
    if heap_entries:
        lines.append("| Category | Mean Heap (MB) | Max Heap (MB) |")
        lines.append("|---|---|---|")
        for label, s in heap_entries:
            lines.append(f"| {label} | {s['mean']} | {s['max']} |")
    lines.append("")

    # 7. Thermal drift
    lines.append("## 7. Thermal Throttling Analysis")
    lines.append("")
    lines.append(_analyze_thermal_drift(data["results"]))
    lines.append("")

    # 8. Methodology
    lines.append("## 8. Methodology")
    lines.append("")
    lines.append("- Each query is run through `RagPipeline.generateResponse()` directly from a standalone `BenchmarkActivity` (no Flutter overhead)")
    lines.append("- The benchmark runs in a separate Android process (`:benchmark`) isolated from the main app")
    lines.append("- A warmup query is executed before timed runs to ensure the LLM engine is fully initialized")
    lines.append(f"- {config['cooldown_ms']}ms cooldown between queries to mitigate thermal throttling")
    lines.append("- TTFT is measured as time from generation start to first non-empty token callback")
    lines.append("- Decode time is measured from first token to generation complete")
    lines.append("- Token count is estimated at ~4 characters per token (Gemma tokenizer average for English)")
    lines.append("- Retrieval time includes Gecko embedding of the query + SQLite cosine similarity search (top 3 docs)")
    lines.append(f"- Generation params: temperature={config['temperature']}, top_p={config['top_p']}, top_k={config['top_k']}")
    lines.append("- No conversation history is used (single-turn queries only)")
    lines.append("")
    lines.append("---")
    lines.append(f"*Report generated from benchmark run `{timestamp}`. Device: {device['manufacturer']} {device['model']}.*")
    lines.append("")

    report = "\n".join(lines)
    with open(output_path, "w") as f:
        f.write(report)
    print(f"Report written to {output_path}")


# ── Main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="MAM-AI on-device latency benchmark",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python evaluation/benchmark_latency.py                          # Default: 3 repeats, all queries
  python evaluation/benchmark_latency.py --repeats 5              # More repeats for tighter stats
  python evaluation/benchmark_latency.py --filter short           # Only short queries
  python evaluation/benchmark_latency.py --filter long_01         # Single specific query
  python evaluation/benchmark_latency.py --no-retrieval           # Skip RAG retrieval
  python evaluation/benchmark_latency.py --cooldown 10000         # Longer cooldown (thermal)
        """,
    )
    parser.add_argument("--repeats", type=int, default=3,
                        help="Repetitions per query (default: 3)")
    parser.add_argument("--cooldown", type=int, default=5000,
                        help="Cooldown between queries in ms (default: 5000)")
    parser.add_argument("--no-retrieval", action="store_true",
                        help="Skip RAG retrieval (generation only)")
    parser.add_argument("--filter", type=str, default=None,
                        help="Filter by category (short/medium/long) or query ID (e.g., long_01)")
    parser.add_argument("--output-dir", type=str, default="evaluation/latency_results",
                        help="Directory for output files")
    parser.add_argument("--device", type=str, default=None,
                        help="ADB device serial (for multiple devices)")
    parser.add_argument("--timeout", type=int, default=7200,
                        help="Timeout in seconds (default: 7200)")
    args = parser.parse_args()

    print("=" * 60)
    print("MAM-AI On-Device Latency Benchmark")
    print("=" * 60)

    # Pre-flight checks
    check_device(args.device)
    check_models_downloaded(args.device)

    # Output directory
    os.makedirs(args.output_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")

    # Force stop any running instance
    print("Stopping app...")
    force_stop_app(args.device)
    time.sleep(2)

    # Clear logcat
    clear_logcat(args.device)

    # Launch benchmark
    print(f"Launching: {args.repeats} repeats, {args.cooldown}ms cooldown, filter={args.filter}")
    launch_benchmark(
        device_serial=args.device,
        repeats=args.repeats,
        cooldown_ms=args.cooldown,
        skip_retrieval=args.no_retrieval,
        query_filter=args.filter,
    )

    # Wait for completion
    success = wait_for_completion(args.device, timeout_s=args.timeout)
    if not success:
        print("Benchmark did not complete successfully.")
        sys.exit(1)

    # Pull results
    json_path = os.path.join(args.output_dir, f"benchmark_{timestamp}.json")
    pull_results(args.device, json_path)

    # Load and analyze
    with open(json_path) as f:
        data = json.load(f)

    analysis = analyze_results(data)

    # Save analysis
    analysis_path = os.path.join(args.output_dir, f"benchmark_{timestamp}_analysis.json")
    with open(analysis_path, "w") as f:
        json.dump(analysis, f, indent=2)
    print(f"Analysis saved to {analysis_path}")

    # Generate report
    report_path = os.path.join(args.output_dir, f"benchmark_{timestamp}_REPORT.md")
    generate_report(data, analysis, report_path)

    # Print summary
    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    if "overall" in analysis:
        o = analysis["overall"]
        print(f"  Total runs:           {o['n_runs']}")
        print(f"  Mean TTFT:            {_fmt(o['ttft_ms'])}ms")
        print(f"  Mean decode:          {_fmt(o['decode_ms'])}ms")
        print(f"  Mean total query:     {_fmt(o['total_query_ms'])}ms")
        tps = o.get("decode_throughput_tps", {})
        if tps:
            print(f"  Mean decode t/s:      {_fmt(tps)}")
    print(f"\n  Results:  {json_path}")
    print(f"  Analysis: {analysis_path}")
    print(f"  Report:   {report_path}")


if __name__ == "__main__":
    main()
