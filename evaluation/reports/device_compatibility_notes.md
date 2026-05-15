# MAM-AI Device Compatibility — On Which Phones the Model Can Run

_Last updated: 2026-05-15. Companion to `latency_report_v2.md` (timing data) and the NPU feasibility report (`mamaretrieval/notes/npu_feasibility_report.md`)._

## TL;DR — three load-bearing rules

1. **E4B minimum RAM: 6 GB** total. 4 GB phones cannot run E4B reliably (model alone needs ~3.3 GB at runtime; Android + bundled apps eat 1.5–2 GB).
2. **E2B minimum RAM: 4 GB** total. The smaller model halves the runtime memory footprint (~1.7 GB), opening up the $100–$150 device tier that's the largest slice of the African market.
3. **E4B on CPU: k=3 is the borderline.** Beyond k=3, CPU totals exceed the 60 s budget on most mid-tier silicon. **E4B on GPU: no latency worry** — totals stay 13–25 s across k=0–15 on Snapdragon 8 Elite + Adreno.

The catch — covered in §3 below — is that **GPU only works reliably on Adreno** (Snapdragon). For the bulk of the African deployment fleet (MediaTek + Mali GPUs), **plan as CPU-only** and treat any GPU acceleration as a bonus, not a guarantee.

---

## 1. Hardware floor

### Storage (free, after install)

| Component | Size |
|---|---|
| APK | 193 MB |
| Gemma 4 E4B `.litertlm` | 3.66 GB |
| Gemma 4 E2B `.litertlm` (alternative) | 2.59 GB |
| Gecko embedding model | 139 MB |
| SentencePiece tokenizer | 776 KB |
| `embeddings.sqlite` (RAG vector index) | ~90 MB |

**Required free storage:**
- For **E4B**: ≥ 6 GB free (4.3 GB minimum for assets + headroom for cache and updates).
- For **E2B**: ≥ 5 GB free.

### RAM (total device memory)

The model's runtime memory is the binding constraint. Numbers from the litert-community HF model cards (tested on Samsung S26 Ultra):

| Model | Runtime CPU memory | Runtime GPU memory |
|---|---:|---:|
| **Gemma 4 E4B** | **3,283 MB** | 710 MB |
| **Gemma 4 E2B** | **1,733 MB** | 676 MB |

Add ~200 MB for the Flutter/Android app heap and ~1.5–2 GB for Android system + bundled apps. So the practical RAM minimums are:

| Model | Hard minimum total RAM | Recommended total RAM |
|---|---|---|
| **Gemma 4 E4B** | **6 GB** | 8 GB |
| **Gemma 4 E2B** | **4 GB** | 6 GB |

At hard minimum, the app will install and run but will be vulnerable to OOM kills under any multitasking. Recommended values give comfortable headroom for normal use.

### CPU architecture

`arm64-v8a` only. LiteRT-LM doesn't ship 32-bit native libs. About 5% of African low-end phones (sub-$70) are still 32-bit-only and are simply incompatible.

### Android version

`minSdk = 24` (Android 7.0) per `app/android/app/build.gradle.kts`. In practice, **Android 8.0 / API 26+** is the effective floor because the app uses `NotificationChannel` and foreground-service patterns that require API 26.

### Network (first launch only)

~4 GB of model files download from HuggingFace on first launch. After that, the app runs fully offline. Plan for Wi-Fi or substantial mobile-data quota at install time.

---

## 2. Backend × model × k feasibility (UX at 60 s budget)

Median total query latency targets, measured on Snapdragon 8 Elite (test device) and extrapolated for mid-tier MediaTek (~2× slower CPU than 8 Elite). E2B numbers are projections (~2× faster than E4B on the same hardware) until we collect actual measurements.

### Gemma 4 E4B

| Backend × hardware tier | k=0 (no-RAG) | k=3 | k=5 | k=10 | k=15 |
|---|---|---|---|---|---|
| **GPU, Snapdragon 8 Elite (Adreno 830)** | 13 s ✅ | 19 s ✅ | 20 s ✅ | 21 s ✅ | 24 s ✅ — **no worry at any k ≤ 15** |
| **CPU, Snapdragon 8 Elite** | 27 s ✅ | 41 s ✅ | 60 s 🟡 | 70 s ❌ | 85 s ❌ |
| CPU, mid-tier MediaTek (~2× slower) | ~50 s 🟡 | ~80 s ❌ | — | — | — |

→ For E4B: **CPU is unsafe past k=3** on flagship hardware, and unsafe at any k > 0 on mid-tier. GPU works at all k tested.

### Gemma 4 E2B (projected, halve E4B numbers)

| Backend × hardware tier | k=0 | k=3 | k=5 | k=10 | k=15 |
|---|---|---|---|---|---|
| GPU, Snapdragon 8 Elite | ~6 s ✅ | ~10 s ✅ | ~10 s ✅ | ~11 s ✅ | ~12 s ✅ |
| CPU, Snapdragon 8 Elite | ~13 s ✅ | ~20 s ✅ | ~30 s ✅ | ~35 s ✅ | ~42 s ✅ |
| **CPU, mid-tier MediaTek** | ~25 s ✅ | ~40 s ✅ | ~55 s 🟡 | ~70 s ❌ | — |

→ For E2B on mid-tier MediaTek CPU, k≤3 is comfortable; k≤5 is borderline. **Empirical measurement still pending.**

---

## 3. GPU backend reliability — Adreno only

LiteRT-LM 0.11.0 uses **OpenCL** for the GPU backend. Whether it actually engages depends on the device's GPU driver. Status by family:

| GPU vendor + family | OpenCL exposed? | Backend works? | Common chipsets |
|---|---|---|---|
| **Qualcomm Adreno** | ✅ Yes, all generations | ✅ **Reliable** | All Snapdragons (any era) |
| **ARM Mali** (Valhall / 5th-Gen) | ⚠️ Varies by OEM driver build | ⚠️ Often silent failure | MediaTek Dimensity / Helio (the African mid-tier majority) |
| **Samsung Xclipse / AMD RDNA** | ✅ exposed | ❌ MLDrift kernel rejected (Issue #2114) | Galaxy S22+ Exynos variants |
| **Google Mali on Tensor** | ❌ **Not exposed** by Google | ❌ Silent fail | All Pixels (Tensor G1/G2/G3/G4) |
| PowerVR | Unknown | Untested | Pixel 10 (Tensor G5) |

### What "silent failure" means

`Backend.GPU()` constructs successfully → first inference call crashes with `"Can not find OpenCL library"` or `"kernel build failure"`. The app's existing try/catch in `RagPipeline.kt` recovers by falling back to CPU, so the app never crashes — but **you also can't predict GPU availability per device**. You can only know at runtime, after the first inference.

### Implication for African deployment

The bulk of the deployment fleet is **MediaTek-powered Transsion (Tecno, Infinix, itel) devices with Mali GPUs.** LiteRT-LM compatibility on these is largely untested in the open and ranges from "works fine" to "kernel compile fails silently." Without per-device empirical testing, you cannot promise GPU acceleration in the field.

**Safe deployment assumption: plan UX commitments around CPU performance on a representative MediaTek device. Any GPU speedup is a bonus.**

---

## 4. NPU backend — promising for Snapdragon flagships, not deployable now

See `mamai/issues/58` and `mamaretrieval/notes/npu_feasibility_report.md` for the full status.

- **Runtime API** (`Backend.NPU(...)` in LiteRT-LM 0.11.0) is shipped.
- **QAIRT native libs** are available from Qualcomm.
- **Model artifact** is the blocker: `gemma-4-E4B-it_qualcomm_sm8750.litertlm` doesn't exist yet on HuggingFace. Only E2B has the Qualcomm SM8750 build today.
- NPU is **Snapdragon-only**. The 80% of African phones running MediaTek would need a separate MediaTek-APU-compiled artifact, which doesn't exist for Gemma 4 at any size.

Status: long-tail watch, recheck HF monthly. Integration is a ~1 day patch when the E4B artifact lands.

---

## 5. African deployment market mapping

Combining the SoC distribution data with the floor specs above:

| Phone class | Example | Chipset | RAM | E4B floor | E2B floor | GPU likely? |
|---|---|---|---|---|---|---|
| Sub-$100 entry | Tecno Spark 10C, itel P55, Infinix Hot 30i | Helio G36/G37 or Unisoc T606 | 2–4 GB | ❌ | ⚠️ 4 GB SKUs OK | ❌ unlikely |
| $100–$150 low-mid | Tecno Camon, Infinix Hot Pro+, Redmi 13C | Helio G99, Dimensity 6080 | 6 GB | ✅ tight | ✅ comfortable | ⚠️ uncertain |
| $150–$250 mid | Tecno Camon 30, Infinix Note 40, Redmi Note 13, Samsung A25 | Dimensity 7050/7200/8400 | 8 GB | ✅ | ✅ | ⚠️ uncertain (Mali) |
| $250+ upper-mid | OnePlus Nord, Samsung A5x | Snapdragon 7+ Gen 3 | 8 GB | ✅ | ✅ | ✅ Adreno |
| $400+ flagship | OPPO Find X8 (our test device), Pixel, Galaxy S | Snapdragon 8 Elite, Dimensity 9400, Tensor | 12+ GB | ✅ | ✅ | ✅ Adreno (Pixel ❌) |

**Effective deployment-viable hardware floor**: roughly **$120+ retail**, 6 GB RAM, 64 GB storage, any 64-bit chipset from 2022 or later. E2B lowers this to **~$100**, 4 GB RAM.

---

## 6. Open questions / pending validations

| Question | How to answer | Priority |
|---|---|---|
| Actual E2B CPU latency at k=0/3/5/7/10/15 on Snapdragon 8 Elite | Same `benchmark_latency.py` sweep run we did for E4B, with the E2B model swapped in | High — unblocks the E2B-vs-E4B deployment decision |
| Does GPU backend engage on real Transsion / MediaTek mid-tier devices? | Borrow / buy a Tecno Camon 30 or Infinix Note 40 and run benchmark with `useGpuForLlm=true`; check `[BACKEND]` log line | High — answers whether GPU is realistic for the deployment majority |
| E2B answer-quality regression vs E4B on safety-critical medical-advice metrics | Re-run `eval_report_app_parity_v1.md` apparatus with E2B model | Critical before any model swap decision |
| Does Exynos Xclipse driver bug get fixed upstream | Watch LiteRT-LM Issue #2114 | Low — affects ~5% of African market |
| When does E4B Qualcomm SM8750 NPU artifact ship | Watch `litert-community/` HF repo monthly per Issue #58 | Medium — perf upgrade, not a deployment unblocker |

---

## 7. Recommended one-line spec for procurement / marketing

> **MAM-AI runs on any Android 8+ phone with 6 GB RAM and 6 GB free storage on a 64-bit chipset from 2022 or later.** For phones with under 6 GB RAM (the majority of sub-$120 African devices), a smaller-model build (E2B) lowers the floor to 4 GB RAM and 5 GB free storage, at some answer-quality cost.

---

## Cross-references

- `evaluation/reports/latency_report_v2.md` — full GPU/CPU latency sweep on Snapdragon 8 Elite
- `evaluation/reports/eval_report_app_parity_v1.md` — answer-quality eval (current E4B-vs-others)
- `mamai/issues/58` — NPU artifact watch (Snapdragon SM8750)
- `mamai/issues/48` — existing discussion on reconsidering deployment model
- `mamaretrieval/notes/npu_feasibility_report.md` — full NPU feasibility analysis
- LiteRT-LM Issue #1860 — Tensor G3 OpenCL not exposed (and by extension G2)
- LiteRT-LM Issue #2114 — Samsung Exynos Xclipse kernel-compile failure
- LiteRT-LM Issue #774 — `TF_LITE_AUX not found` (mismatched model artifact on NPU path)
