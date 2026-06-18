# EmbeddingGemma + Gemma 3n upgrade — implementation plan

**Audience:** engineers working in THIS repo (the MAM-AI Android app). The evidence/reports referenced below live in the separate **`nmrenyi/mamai-eval`** repo.
**Source of truth (why):** in the `nmrenyi/mamai-eval` repo — `configs/config-v0.2.0/reports/r2c-retriever-generator-synthesis-20260618.html` (+ sub-reports `r2c-embedder/`, `r2c-rerank/`, `r2c-threshold/`). This doc translates those
recommendations into concrete app-side steps. **Both changes are now cleared to ship** — the earlier Gemma 3n questions are resolved (§2); what remains is the implementation work, prerequisites, and one safety caveat to record.

---

> ## ⏱️ Implementation status (2026-06-18)
> The two changes are being shipped **independently** (as §0 advises):
> - **Gemma 3n generator swap — ✅ DONE (this PR).** `app_config.json` now points at `gemma-3n-E4B-it-int4.litertlm`; download wiring, size guard, UI/labels updated. Verified on a real device: model init + RAG retrieval (3 docs) + grounded, cited answers + correct emergency escalation ("Heavy bleeding is an emergency. Immediately escalate…"). The official model repo is license-gated, so the app downloads from an ungated mirror and verifies a **pinned SHA-256** before use. The kenya-SAQ harm-flag caveat (§2) is recorded for post-ship monitoring.
> - **EmbeddingGemma retriever swap — ⏳ DEFERRED to a separate PR.** Blocked on artifacts that don't exist yet in any repo (see §5): no on-device int8 LiteRT export, no EmbeddingGemma `Embedder` in the RAG SDK (a custom `Embedder<String>` must be written), and the corpus must be re-embedded into a new `embeddings.sqlite` bundle in the producer repo. The eval validated EmbeddingGemma only via server-side PyTorch (`sentence_transformers`), not LiteRT. Tracked for follow-up.

---

## 0. TL;DR for the implementer

| Change | Status | Expected answer-quality effect | Why |
|---|---|---|---|
| **EmbeddingGemma** (replace Gecko retriever) | ✅ **Ready** (with prerequisites below) | **~0 today** | Best deployable retriever; low-risk; sets up future G-RAG. NOT an answer-quality win on the current generator. |
| **Gemma 3n** (replace Gemma 4 generator) | ✅ **Ready** (ship with a noted safety caveat) | **Large** (~2× kenya recall; +8 pp hb completeness) | Biggest lever found. Earlier questions resolved: the 3n→4 move was just "newer version" (no technical reason), and the lone safety red flag is noted + monitored, not blocking — see §2. |

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

## 2. Gemma 3n — generator swap (READY — ship with a noted safety caveat)

### What the evidence says
Swapping the device generator **Gemma 4 E4B → Gemma 3n E4B** roughly **doubles** kenya key-fact recall
(0.115 → 0.270) and adds ~8 pp healthbench completeness, uniformly across every retriever. This is the
single largest lever found, and per the decisions below it is **cleared to ship.**

### The two earlier questions — both resolved
1. **The 3n → 4 move was not technical.** Gemma 4 was adopted simply because it's the **newer version** —
   no latency/size/quality regression drove it. So reverting to 3n reintroduces **no known problem**; it's a
   deliberate, low-risk choice.
2. **Safety: one red flag, recorded and accepted (not a blocker).** Across metrics 3n is at least as safe as
   Gemma 4 — on the healthbench rubric its penalty rate is slightly *lower*. The single exception is the
   kenya-SAQ **harm-flag** metric, where 3n scored worse (~0.32 vs ~0.19). **Decision: note this caveat and
   ship** — it's one flag against a large, consistent completeness gain, and rubric-level safety favors 3n.
   **Mitigation:** keep the harm-flag metric in the post-ship eval and watch it; revisit only if it regresses
   in production.

### Implementation
- `app_config.json` `llm_model`: `gemma-4-E4B-it.litertlm` → the **Gemma 3n E4B** `.litertlm` artifact.
- Confirm the `gemma-3n-E4B-it` `.litertlm` runs acceptably on the target device (latency/RAM) — a normal
  pre-ship deployability check, not a gate (3n was the predecessor on-device, so it's expected to pass).
- Re-run on-device answer parity, **carrying the kenya-SAQ harm-flag metric** in that check per the safety
  note above.

---

## 3. Sequencing guidance (important)

The generator is the **binding constraint** on answer quality; retrieval is not. So:

- **Gemma 3n is the answer-quality win and is now cleared to ship** (§2): ~2× kenya recall, +8 pp hb
  completeness — the highest-leverage change in this doc.
- **EmbeddingGemma alone won't improve answers** on Gemma 4 (RAG is net-neutral there). Ship it for
  retrieval quality, because it never hurts on 3n, and because it's where RAG first pays off end-to-end
  (EmbeddingGemma×3n is the one config that beats no-RAG) — but don't sell it as a standalone quality fix.
- **G-RAG** (grounding the generator to actually use retrieved context) remains a separate, deeper lever for
  turning retrieval into answers — out of scope here.
- **No retrieval-side abstention/confidence gate is available** (the thresholdability report: cosine and
  reranker scores can't predict when RAG helps). If a confidence gate is wanted, it must be generator-side.

Suggested order: **ship Gemma 3n** (the real gain) and **EmbeddingGemma** (low-risk; together they're where
RAG first converts) → then pursue **G-RAG**.

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
