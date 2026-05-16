# Runbook: Gemma 4 E2B Latency Sweep

Self-contained instructions for finishing the E2B latency sweep started by another session. **Phase 1 (setup) is already complete on branch `feat/e2b-latency-sweep`.** Your job is Phase 2 (GPU sweep), Phase 3 (CPU sweep), and Phase 4 (analysis + local commits, **no push**). Expected wall-clock: **~5 hours**.

## 0. Context — read this first

- This work mirrors the E4B latency sweep that landed in PR #57 (commit `1be0a55` on `main`). The E4B results are in `evaluation/reports/latency_report_v2.md` and the device-compatibility analysis is in `evaluation/reports/device_compatibility_notes.md`.
- We're now measuring the **smaller** Gemma 4 E2B variant (~2 GB instead of E4B's 3.66 GB) to find out how much faster it is in real terms on the same hardware. Same 16 measurements as E4B: 8 GPU (k ∈ {1, 3, 5, 7, 10, 15, 20} + No-RAG) + 8 CPU.
- Test device: **OnePlus OPD2413 (Snapdragon 8 Elite, SM8750P)** connected via ADB — that's the firmware-reported manufacturer (`device.manufacturer="OnePlus"` in the benchmark JSONs); the same OPD2413 hardware ships under the OPPO brand in some markets. The OPPO/OnePlus Hans battery-optimization whitelist is **already configured** by the user — don't re-do it.
- The benchmark infrastructure is in `evaluation/benchmark_latency.py`; the aggregator is `evaluation/aggregate_k_sweep.py`. Both are already correct for this work, with one expected exception in Phase 4 (the aggregator needs a `model` dimension added).

### Why this is a runbook and not a single Bash command

Each benchmark run takes **12–20 minutes wall-clock** (E2B is ~1.5× faster than E4B based on the smoke test, not 2×). You can't realistically loop them in one foreground shell command; bash timeouts cap at 10 minutes in our tooling. Use `Bash run_in_background: true` and **wait for the harness completion notification** between runs. Don't use `tail -F`, sleep loops, or watchdog patterns — those caused the previous subagent to bail at 87 seconds.

---

## 1. Verify Phase 1 state — fail loud if anything's missing

Run these checks before touching anything:

```bash
cd ~/Downloads/mamai
git status                       # should show clean working tree on branch feat/e2b-latency-sweep
git log --oneline -3             # should show 3042d38, 976a8ac at the top
```

Expected log:
```
3042d38 config: switch llm_model to Gemma 4 E2B
976a8ac fix(benchmark): read model name from app_config asset
a2205ff docs: device compatibility notes — which phones can run E4B / E2B
```

```bash
ls -lh device_push/models/gemma-4-E2B-it.litertlm   # ~2.4–2.6 GB
adb devices                                          # should show one device
adb shell ls /storage/emulated/0/Android/data/com.example.app/files/
# expect to see: gemma-4-E2B-it.litertlm, gemma-4-E4B-it.litertlm,
#                Gecko_1024_quant.tflite, embeddings.sqlite, sentencepiece.model
```

The smoke-test JSON from Phase 1 is at `evaluation/latency_results/benchmark_20260515T150531_k3.json`. Verify it has `config.model == "gemma-4-E2B-it.litertlm"`, `config.backend == "GPU"`, no errors, total latency 11036 ms.

If anything fails any of these checks, **stop and ask the user** — the state has drifted from what this runbook assumes.

---

## 2. Phase 2 — GPU sweep (~1.5–2 hours)

The GPU APK from Phase 1 is already installed. Run these 8 benchmarks **sequentially**, each via `Bash run_in_background: true`, waiting for the harness completion notification before launching the next:

```bash
cd ~/Downloads/mamai
python evaluation/benchmark_latency.py --retrieve-k 1 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --retrieve-k 3 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --retrieve-k 5 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --retrieve-k 7 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --retrieve-k 10 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --retrieve-k 15 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --retrieve-k 20 --rag-only --cooldown 10000
python evaluation/benchmark_latency.py --no-retrieval --cooldown 10000
```

### How to actually do this with the Bash tool

For each command:

1. Call `Bash` with `run_in_background: true` and the command. Save the returned task ID.
2. **Stop and wait.** The harness will send a `<task-notification>` message when the python process exits. That's your signal to continue.
3. When the notification arrives, read the resulting JSON in `evaluation/latency_results/benchmark_*_k{N}.json` (or for No-RAG, no `_kN` suffix).
4. Verify the JSON:
   - `config.model == "gemma-4-E2B-it.litertlm"`
   - `config.backend == "GPU"`
   - `len(results)` == 54
   - Errors == 0 (except k=20, which is expected to error on the same 8 queries × 3 reps = 24 errors that hit the 4096-token wall in the E4B sweep)
   - TTFT median in the 500–2000 ms range
5. If anything looks wildly off, stop and report. Otherwise proceed to the next k.

Per-run wall-clock estimate (based on E4B GPU being ~12–30 min per k, and E2B being ~1.5× faster):
- ~10–15 min per k for small k
- ~12–20 min per k for k ≥ 10

Total Phase 2: **~1.5–2 hours**.

### Optional progress visibility (not required)

If you want occasional progress pings while a benchmark runs, you can launch a `Monitor` with timeout=3600000ms (1 hour) and a poll command that greps `adb logcat -d` for `mam-ai-bench` lines. Examples in the PR #57 history. But this is just visibility — the harness completion notification is what gates "move on."

### Checkpoint 2 — what to report when Phase 2 is done

After all 8 GPU JSONs land, summarize:
- List of file names produced
- Per-run wall-clock (from `total_benchmark_time_ms` field divided by 60000)
- Error counts (should be all zero except k=20)
- Quick comparison to E4B GPU baseline: did E2B run roughly 1.3–1.7× faster overall? Numbers from `evaluation/reports/latency_report_v2.md` are easy to compare against.

Then **stop and ask the user** before starting Phase 3.

---

## 3. Phase 3 — CPU rebuild + sweep (~3 hours)

### 3a. Switch to CPU build

```bash
cd ~/Downloads/mamai/app
flutter build apk --release -PuseGpuForLlm=false
```

(foreground `Bash` with `timeout: 600000` — should complete in ~30 sec since artifacts are cached). Verify `Built build/app/outputs/flutter-apk/app-release.apk`.

```bash
adb install -r ~/Downloads/mamai/app/build/app/outputs/flutter-apk/app-release.apk
```

(foreground `Bash`, ~2 min). The `-r` flag preserves existing model files on the device. Verify with `adb shell ls /storage/emulated/0/Android/data/com.example.app/files/` — should still show both `gemma-4-E2B-it.litertlm` and the others.

### 3b. CPU smoke test

```bash
cd ~/Downloads/mamai
python evaluation/benchmark_latency.py --filter medium_01 --repeats 1 --rag-only --retrieve-k 3 --cooldown 5000
```

(background, wait for notification). Verify the resulting JSON has `config.backend == "CPU"`, `config.model == "gemma-4-E2B-it.litertlm"`. Expected total latency ~15–20 s (E2B CPU at k=3 should be ~1.5× faster than E4B CPU's ~37–44 s).

If smoke test passes, proceed.

### 3c. CPU sweep — same 8 benchmarks

Identical command list as Phase 2. Same background + notification-wait pattern. Per-run expected ~20 min (E2B CPU is ~1.5× faster than E4B CPU's ~40–90 min).

Verify each JSON: backend=CPU, model=E2B, run count, error count.

### Checkpoint 3 — what to report

Same shape as Checkpoint 2: file names, per-run wall-clock, error counts, comparison to E4B CPU baseline.

Stop and ask the user before starting Phase 4.

---

## 4. Phase 4 — Analysis + local commits (do NOT push)

### 4a. Update the aggregator to handle two models

Currently `evaluation/aggregate_k_sweep.py` groups by `(backend, k)`. With E4B and E2B both present, the matrix would collapse them into the same cells. **Add a `model` dimension**: change the grouping to `(model, backend, k)`.

Key places to touch:
- `load_runs()` — append `"model": d["config"].get("model") or DEFAULT_E4B_MODEL` to each run dict. For the pre-fix E4B GPU JSONs (the ones in `PRE_FIX_GPU_FILES`), they predate the model-recording fix and don't have `config.model` either — they should default to `"gemma-4-E4B-it.litertlm"`. Add a `PRE_FIX_E4B_FILES` allowlist similar to `PRE_FIX_GPU_FILES`, or just bake it into a single `_legacy_default_for(filename)` helper.
- The `matrix` dict in `write_report()` — change the key from `(backend, k)` to `(model, backend, k)`.
- Each table that loops over `all_ks` needs to also loop over models, or you can produce a table per model.

Expected size of change: ~50 LOC. Run `python3 evaluation/aggregate_k_sweep.py` and verify it loads all 32 canonical runs (16 E4B + 16 E2B).

### 4b. Update `latency_report_v2.md`

Add an **E4B vs E2B comparison** section. Key tables:
- Median total query latency: rows = k, columns = `{E4B GPU, E2B GPU, E2B÷E4B ratio, E4B CPU, E2B CPU, E2B÷E4B ratio}`. One table per category (short / medium / long) or per overall.
- TTFT comparison same shape.
- Decode comparison same shape — this is where we expect E2B's gain to be smallest (decode is bandwidth-bound).

Update the **Key findings** section to reflect the measured ratio. The smoke test suggested ~1.5× (not the 2× originally projected). Decode being bandwidth-bound is the architectural reason — call that out.

Update the document title from "GPU vs CPU" to something like "Model × Backend × k" or "Latency Sweep — Gemma 4 E2B vs E4B, GPU vs CPU".

### 4c. Update `device_compatibility_notes.md`

- Section §6 "Open questions": mark "Actual E2B CPU latency" as **resolved** with real numbers from the new sweep.
- Section §2 "Backend × model × k feasibility": replace the **projected** E2B table with real measurements. Specifically replace the row "CPU, mid-tier MediaTek (~2× slower)" which was extrapolation — the new data lets us anchor more precisely.
- TL;DR section: refine any rule-of-thumb that was based on the wrong 2× ratio. The actual ratio is ~1.5× — adjust deployment recommendations if anything changes.

### 4d. Commit, do NOT push

Make focused commits matching the PR #57 style. Suggested split (your call on exact phrasing):

1. `analysis: aggregate_k_sweep.py — add model dimension to matrix`
2. `analysis: regenerate latency_report_v2.md with E2B columns`
3. `docs: update device_compatibility_notes.md with E2B measurements`

After all commits, run `git log --oneline origin/main..HEAD` and report the commit list to the user. **Do not push.**

---

## 5. Failure-mode guidance

| Symptom | Action |
|---|---|
| Bash command times out (foreground) | Use background mode + notification wait instead. Foreground is for builds/installs only. |
| Background task takes 30+ min with no completion notification | Run `pgrep -af benchmark_latency.py` to verify python is still alive. If it is, keep waiting. If not, the benchmark died — read the task's output file and report. |
| Benchmark JSON missing fields (no `config.model`, wrong backend, etc.) | Stop. The build or install drifted. |
| Hans freeze events in logcat (`OplusHansManager: freeze ... scene: LcdOff`) | Shouldn't happen — the foreground-service + whitelist fix is in main. If it does, the whitelist may have been reset by a system update. Stop and ask the user to re-verify it in Settings. |
| App on device dies between benchmarks | Check `adb shell pm list packages \| grep com.example.app`. If missing, the install was rolled back somehow — stop. |
| Smoke-test totals wildly off (e.g. >60s at k=3 GPU, or >5s at k=3 No-RAG) | Stop. Something is wrong with the build or backend selection. |

For any "wildly off" result, stop and report rather than auto-retry. The user can decide whether to re-do the run or investigate.

---

## 6. Constraints

- **Branch**: `feat/e2b-latency-sweep` only. Don't push to origin. Don't rebase or amend `main` or anything earlier than your own commits.
- **Don't touch the mamaretrieval repo.** All work happens in mamai.
- **Don't change scope.** If the plan is ambiguous on something specific, stop and ask the user rather than improvising. Specifically, don't:
  - Change the k-value list (must be 1, 3, 5, 7, 10, 15, 20 + No-RAG to match E4B)
  - Change the cooldown (10000 ms)
  - Skip the CPU smoke test
  - Skip any of the 4 deliverable updates in Phase 4
- **Commit style**: match the PR #57 style (`feat:`, `fix:`, `analysis:`, `docs:` prefixes; concise subject line; body explaining "why" not "what").
- **Don't push.** The final state is "16 new JSONs landed, scripts and reports updated, all committed locally on `feat/e2b-latency-sweep`, branch ready for human review and PR creation."

---

## 7. Final-deliverable checklist

Before declaring done, verify:

- [ ] 16 new benchmark JSONs in `evaluation/latency_results/` — 8 with backend=GPU, 8 with backend=CPU, all with model=E2B
- [ ] `aggregate_k_sweep.py` updated to handle `(model, backend, k)` grouping; loads all 32 canonical runs without errors
- [ ] `latency_report_v2.md` regenerated and updated with E4B vs E2B narrative
- [ ] `device_compatibility_notes.md` updated to reflect measured E2B numbers
- [ ] All changes committed in focused commits on `feat/e2b-latency-sweep`
- [ ] **Branch not pushed**
- [ ] Summary report: commit list, headline findings (per-backend E2B vs E4B median latency at k=3, k=10), any anomalies observed

When done, hand back to the user for review + PR creation.

---

_Last updated: 2026-05-15. Phase 1 commits already on the branch: `976a8ac` (model-from-config fix), `3042d38` (config switch to E2B). Phase 1 smoke test: `benchmark_20260515T150531_k3.json`, total 11036 ms at k=3 GPU._
