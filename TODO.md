# Work Tracking

This repo does not use `TODO.md` as an actionable task list anymore.

GitHub issues are the source of truth. Keep this file only as a lightweight index of the current work order. Do not add new local TODO items here; open or update a GitHub issue instead.

## Current Priority Order

1. [#43](https://github.com/nmrenyi/mamai/issues/43) Re-run the full `app_parity_v1` evaluation matrix and refresh reports
2. [#42](https://github.com/nmrenyi/mamai/issues/42) Build a doc-grounded benchmark from the bundled clinical guideline corpus
3. [#41](https://github.com/nmrenyi/mamai/issues/41) Add retrieval-only evaluation for the bundled guideline corpus
4. [#40](https://github.com/nmrenyi/mamai/issues/40) Prototype agentic guideline search with LiteRT-LM tool calling

## Related Issues

- [#22](https://github.com/nmrenyi/mamai/issues/22) Experiment with retrieval parameters (`top_k`, threshold)
- [#34](https://github.com/nmrenyi/mamai/issues/34) RAG evaluation strategy: frameworks, metrics, gaps, and potential contributions
- [#35](https://github.com/nmrenyi/mamai/issues/35) Explore Gemma 4 tool use / function calling capabilities
- [#36](https://github.com/nmrenyi/mamai/issues/36) Query rewriting: reformulate user input before retrieval to improve RAG quality
- [#37](https://github.com/nmrenyi/mamai/issues/37) MCQ extractor misses Gemma 4 outputs with trailing quote/tag tokens

## Other Open Work

- [#29](https://github.com/nmrenyi/mamai/issues/29) Verify Swahili translations with a medical professional
- [#31](https://github.com/nmrenyi/mamai/issues/31) Model download: decouple from self-hosted VPS
- [#24](https://github.com/nmrenyi/mamai/issues/24) Add confidence / uncertainty signal to the UI
- [google-ai-edge/LiteRT-LM#1850](https://github.com/google-ai-edge/LiteRT-LM/issues/1850) Track GPU decode crash for E4B
