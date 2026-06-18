# EmbeddingGemma + Gemma 3n upgrade — implementation plan

**Audience:** engineers working in THIS repo (the MAM-AI Android app). The evidence/reports referenced below live in the separate **`nmrenyi/mamai-eval`** repo.
**Source of truth (why):** in the `nmrenyi/mamai-eval` repo — `configs/config-v0.2.0/reports/r2c-retriever-generator-synthesis-20260618.html` (+ sub-reports `r2c-embedder/`, `r2c-rerank/`, `r2c-threshold/`). This doc translates those
recommendations into concrete app-side steps and, crucially, **separates what's ready to ship from what's blocked.**

---

## 0. TL;DR for the implementer

| Change | Status | Expected answer-quality effect | Why |
|---|---|---|---|
| **EmbeddingGemma** (replace Gecko retriever) | ✅ **Ready** (with prerequisites below) | **~0 today** | Best deployable retriever; low-risk; sets up future G-RAG. NOT an answer-quality win on the current generator. |
| **Gemma 3n** (replace Gemma 4 generator) | ⛔ **Blocked** — do not ship yet | Large (~2× kenya recall) *if* unblocked | Two open questions must be resolved first (safety harm-flag + why 3n→4 happened). |

The two changes are **independent** — EmbeddingGemma can ship on its own. They're only *synergistic*
in one cell (EmbeddingGemma×3n is the single config where RAG beats no-RAG end-to-end).

> **Set expectations up front:** on the *current* Gemma 4 generator, RAG is net-neutral-to-negative, so
> swapping in EmbeddingGemma will **not** measurably improve answers today. Adopt it as a low-risk
> retrieval-quality upgrade and a prerequisite for the generator-side work (G-RAG) — not as a quality fix.
> If the goal is better answers, the generator (not the retriever) is the lever; see §3.

---

## 1. EmbeddingGemma — retriever swap (READY)

### What it is
Replace the deployed **Gecko** TFLite embedder with **EmbeddingGemma-300M** (int8 LiteRT), 768-dim.
Offline this is a clear retrieval win (kenya P@3 0.270 → 0.396, +12.6 pp; best deployable retriever).

### The non-obvious prerequisite: the corpus must be re-embedded
The shipped vector store holds **Gecko** document vectors. EmbeddingGemma produces different vectors
(different model, 768-dim). **You cannot just swap the query encoder** — the entire corpus must be
re-embedded with EmbeddingGemma and a new vector store built. This is the bulk of the work.

### Steps
1. **Obtain the artifact.** EmbeddingGemma-300M int8 LiteRT export (official). It is **HF-gated**
   (accept the license). On-device footprint measured: ~171 MB disk, ~187 MB peak RAM, seq-len 256.
   - ⚠️ *Gap I can't fill from here:* whether the app repo already has/needs to convert this artifact, and
     where model artifacts are hosted/packaged in the app build.
2. **Re-embed the corpus** (rag-bundle-v0.2.0, ~63,650 chunks) with EmbeddingGemma:
   - Use the **document** encoding path (`encode_document`), **L2-normalized**, **768-dim** (MRL-truncate
     if the export is wider). Reference implementation (in `nmrenyi/mamai-eval`): `retrieval_eval/screen_embedder.py`
     (`embed_retrieve`) does exactly this — mirror its encode settings for parity.
   - Build the new `embeddings.sqlite` (or the app's store format) from these vectors.
3. **Wire the query encoder.** Query embedding must use the **query** path (`encode_query` / query prompt
   prefix) — query and document use different prompts in EmbeddingGemma. 768-dim cosine over the new store.
4. **CPU + int8 only.** The GPU delegate **fails** for all embedders tested (op support) — run on CPU
   (XNNPACK). Do not wire a GPU delegate path.
5. **On-device latency check on a *real* low-/mid Zanzibar device.** Eval numbers were a **flagship proxy**
   (embed ~125 ms @4t / ~249 ms @1t seq256). Net retrieval latency is dominated by the SQLite cosine scan
   (~4 s, embedder-independent), so the swap is expected **latency-neutral-to-better** vs Gecko — but
   confirm on the actual target device before release (single-thread CPU is the binding case).
6. **Validate retrieval parity.** Confirm the app's on-device retrieval reproduces the eval's EmbeddingGemma
   result (kenya top-3 should match the offline P@3 ≈ 0.396 behavior). A small spot-check against the eval's
   retrievals is enough.

### Acceptance / done criteria
- New vector store built with EmbeddingGemma; query path uses the query prompt; 768-dim cosine.
- On-device latency ≤ current Gecko path on the real low-mid device.
- Retrieval parity with the eval spot-checked.
- **Do not gate on answer-quality improvement** — none is expected on Gemma 4 (see §0).

---

## 2. Gemma 3n — generator swap (BLOCKED — do not ship)

### What the evidence says
Swapping the device generator **Gemma 4 E4B → Gemma 3n E4B** roughly **doubles** kenya key-fact recall
(0.115 → 0.270) and adds ~8 pp healthbench completeness, uniformly across every retriever. This is the
single largest lever found — **but the synthesis explicitly gates it.**

### Why it's blocked — two open questions to resolve first
1. **Safety (harm-flag) is metric-dependent.** On the healthbench rubric, 3n's penalty is slightly *lower*
   (safer); but on the earlier **kenya-SAQ harm-flag** metric 3n was **worse** (~0.32 vs ~0.19). Before
   shipping a 2× completeness gain, resolve whether 3n is acceptable on the harm axis — ideally a focused
   safety eval on the deployment SAQ set + a clinical/acceptance sign-off or threshold.
2. **Why did the device move 3n → 4 in the first place?** 3n was the predecessor on-device, so it should be
   deployable, but confirm the original 3n→4 rationale (size? latency? vendor default? a regression we'd
   reintroduce?) so the reversal is **deliberate**, not a silent trade.

### What would unblock it
- A harm-flag safety result for 3n vs 4 on the deployment SAQ set, meeting an agreed acceptance bar.
- Documented confirmation of the 3n→4 rationale + that the `gemma-3n-E4B-it` `.litertlm` runs acceptably on
  the target device (latency/RAM).

### Implementation once unblocked (for reference)
- `app_config.json` `llm_model`: `gemma-4-E4B-it.litertlm` → the Gemma 3n E4B `.litertlm` artifact.
- Re-run on-device parity + the safety/quality checks above.

---

## 3. Sequencing guidance (important)

The generator is the **binding constraint** on answer quality; retrieval is not. So:

- **EmbeddingGemma alone won't improve answers** (RAG is net-neutral on Gemma 4). Ship it for retrieval
  quality + as a G-RAG prerequisite + because it never hurts on the stronger generator — but don't expect
  a metric move, and don't let it be sold as the answer-quality fix.
- **The real answer-quality levers** are (a) the **Gemma 3n** decision (pending §2) and (b) **G-RAG** —
  grounding the generator so it actually uses retrieved context instead of being hurt by it. G-RAG is a
  separate workstream, not in scope here.
- **No retrieval-side abstention/confidence gate is available** (the thresholdability report: cosine and
  reranker scores can't predict when RAG helps). If a confidence gate is wanted, it must be generator-side.

Suggested order: ship **EmbeddingGemma** now (low-risk, independent) → resolve the **3n gates** → pursue
**G-RAG**. EmbeddingGemma + 3n together is where retrieval first pays off end-to-end.

---

## 4. Caveats carried from the eval

- Cluster numbers are **GGUF Q4_0 / flagship proxies** for the on-device `.litertlm`; the *direction*
  (3n ≫ 4; EmbeddingGemma best retriever) is robust, exact magnitudes will shift on-device.
- End-to-end sets are small/medium (kenya 312, healthbench-oss 1209); pre-registered noise floor ~5 pp.
- Do **not** ship a reranker and do **not** fine-tune the embedder (R2d) — both shown not to help kenya.

## 5. Gaps this doc can't fill (need the app repo)
- Exact `app_config.json` schema and the embedder/vector-store/generator wiring points.
- The corpus → vector-store build & packaging pipeline in the app build.
- Model-artifact hosting/provenance (where the EmbeddingGemma LiteRT + Gemma 3n `.litertlm` come from).
- On-device test/CI harness and the real target-device specs.

*An app-repo engineer should fill §5 before starting §1.*
