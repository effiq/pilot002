# Pilot 002 · Protocol Lock (Pre-Registration)

**Version 2.0 ｜ Frozen 2026-10-06 ｜ Status: Active**

Measurement window 2026-10-06 → 2026-11-05 (30 days)
Day-7 checkpoint 2026-10-13 ｜ Day-30 verdict 2026-11-05

This document is the pre-registered protocol for Effiq Pilot 002. Once frozen, no locked item may be modified during data collection. The only legal path for change is a new version (v2.1, v3.0, …) with the reason and date recorded; silent edits are prohibited. Results — PASS or FAIL — will be published with complete evidence. Governance machinery (amendment log, deviation log, hash-pinned artifacts, sealed statistics, `--verify` recomputation entries) is inherited unchanged from Pilot 001 Protocol Lock v1.0 (effiq/pilot001, commit `3faaaa7`).

## 0. Pilot definition

Pilot 001 established that FP8 dynamic quantization is **effective** on a declared synthetic workload (1.419×, CI [1.387×, 1.442×], blind quality gate PASS). Pilot 002 tests the second leg of the operational definition — **stability**: does the speedup hold when the load takes a *real production shape* — a real arrival process with bursts and concurrency, real prompt/output length distributions — instead of a tidy synthetic grid?

Workload: replay of a public production inference trace (timestamps + token counts) against a single-GPU serving stack. Arms unchanged: A = BF16 defaults, B = FP8 dynamic quantization. Success criterion: paired-bootstrap 95% CI lower bound of the throughput ratio ≥ 1.20×, plus a pre-registered tail-latency non-inferiority gate, plus the blind quality gate under serving-mode concurrency.

## 1. Locked items

### L1 — Model

- Primary and only: Qwen2.5-14B-Instruct, revision `cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8` (identical to Pilot 001; both arms load identical weight files, quantization at load time).
- Engine: vLLM, **version pinned at `0.31.0`** for the entire window (the version Pilot 001 ran end-to-end; cross-pilot comparability). Patch-level upgrades are prohibited inside the window — this tightens Pilot 001's "recorded" to "pinned".

### L2 — Workload construction (the changed item)

- **Trace source**: Azure LLM Inference Trace 2024 (one-week production traces), both services: conversation (`conv`) and code completion (`code`). Public download, CC-BY license. Raw file sha256 hashes are recorded after download and published; the trace is a third-party artifact, so its hash is anchored, not frozen by us.
- **What is real, what is synthetic (K7 honesty clause)**: arrival timestamps, per-request prompt token counts (`ContextTokens`) and output token counts (`GeneratedTokens`) come from the production trace. The trace contains no text; prompt bodies are synthetic filler of the declared Pilot 001 style, built to the traced token count. We claim realism of *load shape*, not of content.
- **Slice selection**: from each service's week, 6 one-hour slices are selected by seeded sampler (TRACE_SEED = **20261010**). Formal run *i* replays **slice pair *i*** — the conv slice and the code slice of index *i*, merged onto one timeline (a mixed-service hour: the realistic shape of a shared deployment). The slice index list is computed once, published, and reused identically for both arms.
- **Offered-load calibration**: the trace comes from a multi-GPU production service; one GPU cannot absorb the raw peak rate, and replaying a load the baseline cannot serve would measure collapse, not serving. Offered load is shaped by two pre-registered knobs: deterministic seeded **thinning** (retention r ∈ {1, 1/2, 1/4, 1/8} of arrivals) and **time compression** (C ∈ {4, 8, 16}; an hour replayed in 60/C minutes). A request is SLO-compliant iff TTFT ≤ 5 s and TPOT ≤ 100 ms. **Selection rule**: on a separate **calibration slice pair** (index drawn from the same seed stream, disjoint from the 6 formal pairs; watermarked: CALIBRATION DATA ONLY — never enters the CI, same rule as Pilot 001 Stage 01), run Arm A (BF16) over the (r, C) grid and pick the **heaviest** configuration (largest r × C) at which ≥ 95% of requests are SLO-compliant; ties break toward larger C (shorter wall-clock). If no grid point passes, the lightest configuration (r = 1/8, C = 4) is used and the shortfall is disclosed in the verdict. The chosen (r, C) is then frozen for all runs and both arms.
- **Output lengths**: per-request `max_tokens` = traced `GeneratedTokens`, capped at 1024 (declared cap). Performance-half generation uses `ignore_eos=True` so realized output length equals the traced length (a load-fidelity device, declared). The quality gate does *not* use `ignore_eos` — judged outputs are produced naturally.
- The Pilot 001 frozen 150-item quality set is **reused by hash** (`728b2f83…5cf7d`); constructing a new quality set would constitute a new experiment.

### L3 — Two arms

- Arm A (baseline): BF16 weights, vLLM 0.31.0 server defaults.
- Arm B (optimized): FP8 dynamic quantization (vLLM built-in `quantization="fp8"`; carried over from Pilot 001 Amendment-01 as base design, not an amendment).
- Serving mode: OpenAI-compatible server (`vllm serve`) with an asynchronous replay client; prefix caching OFF; temperature 0.
- All server flags are identical between arms except the quantization flag; any accidental flag difference aborts the run and enters the deviation log.
- Hardware boundary: one 48GB-class GPU, locked to L40S for the entire pilot.
- Explicit non-goals (unchanged): no custom kernels, no engine source modifications, no non-mainline features. Every arm difference must be traceable in config.

### L4 — Measurement protocol

- 6 formal runs; within-run block-crossover (A block and B block over the identical replayed slice pair, order alternating by run parity; inherited from Pilot 001 Amendment-02). If the CI straddles 1.20, runs extend to 10 per the pre-registered rule — never more.
- Per request, recorded per row: request_id, trace slice id, arrival offset, prompt tokens, output tokens, TTFT, mean TPOT, end-to-end latency, wall timestamps, arm, run index/seed, scripts revision, output-ids sha256.
- **Primary statistic (performance)**: per-request throughput := output tokens ÷ end-to-end latency (queue wait included — queueing under load is part of the phenomenon being measured). Ratio B/A paired by request_id within a run → run-level mean log-ratio → paired bootstrap over runs (n = 6; 100,000 resamples; bootstrap seed fixed at **20262002** — fully deterministic). **PASS ⟺ exp(CI lower bound) ≥ 1.20×.** Otherwise FAIL. There is no "close enough".
- **Secondary gate (tail-latency non-inferiority, pre-registered)**: on the pooled formal-run requests, Arm B's P95 TPOT must not exceed Arm A's P95 TPOT by more than 5%, and Arm B's P95 TTFT must not exceed Arm A's by more than 5%. Breach on either metric → FAIL, regardless of the primary statistic. Declared SLO reference for calibration and reporting: P95 TTFT ≤ 5 s, P95 TPOT ≤ 100 ms.
- Anti-p-hacking (unchanged): descriptive means only during the window; the CI stays sealed in the independent verdict script until all COMPLETE markers exist; no extending windows, no dropping outliers, no metric changes mid-measurement; all raw logs retained and published.

### L5 — Quality gate (blind), concurrency edition

- Same frozen 150-item set, same 3-axis 0–10 rubric, same blind-assignment mechanism (new blind seed: **20261011**), same judge policy (non-Qwen-family external judge reachable from the billing region; probe order declared in the gate script), same tolerance: **overall mean delta and every axis delta (B−A) must each be ≥ −0.1; any breach → FAIL**.
- **Change vs Pilot 001**: generation happens in serving mode under declared concurrency (8 concurrent requests). Pre-registered disclosure: under continuous batching, floating-point reduction order makes outputs non-bit-deterministic; the gate therefore compares *judged text quality*, never textual identity. This is a property of the serving stack, declared before data, not an excuse produced after it.

### L6 — Time window, budget, stop-loss

- Total window: 30 days from freeze (2026-10-06 → 2026-11-05). Day-7 checkpoint (2026-10-13): trace pipeline green (download hash verified, slicing/thinning replayable, calibration slice pair replayed) — red pipeline triggers protocol review, window does not extend.
- Day 30 (2026-11-05): no confirmed CI ≥ 1.20× → stop-loss executes: all external narrative work halts; review before any new decision.
- Budget hard cap: GPU $60 + judge API $50 = $110 total. Hitting either cap stops the pilot. Additional spend requires written approval.

### L7 — Publication

- Results (PASS or FAIL) published within 7 days after the window closes: verdict document, hash manifest, reproduction guide, and the complete evidence chain.
- Scripts live in a new public repository `effiq/pilot002` (public from the freeze date — the protocol pre-dates data, so there is nothing to hide); raw logs continue into the public `effiq/pilot-logs` repository under Pilot 002 stage directories.

## 2. Pre-registered exploration space (not locked)

The following may be decided from data inside the window, every change entering the deviation log:

1. Offered-load configuration (r, C) within the pre-registered grid, by the L2 rule (calibration slice pair only).
2. Replay-client implementation details that do not affect offered load (connection pooling, timeouts, retry policy for client-side errors — server-side errors abort the run).
3. Slice re-selection only if a selected slice is demonstrably corrupt (hash mismatch on download); re-selection uses the same seed stream, next draw. If the primary download source becomes unavailable, a public mirror may be substituted; hashes are re-anchored and logged.

## 3. Verification

Every figure published from this pilot is reproducible from artifacts: the public trace (hash-anchored), slicing/thinning scripts (seeds above), raw logs, and verdict scripts that recompute every reported interval from the raw logs in one command (`--verify`). The PASS/FAIL verdict is produced by the statistics script from raw logs — not by narrative.

---

*Frozen 2026-10-06. Signed by the operator. This document ships before any result does.*

*Revision history: v2.0 final incorporates a pre-freeze review (2026-10-06, before any measurement) that corrected three defects in the draft — the quality-gate tolerance clause (restored the overall-delta condition alongside per-axis), the offered-load calibration rule (direction corrected to heaviest SLO-compliant configuration, with thinning grid, SLO-compliance definition, and fallback), and the slice-accounting inconsistency (6 runs now consume 6 merged conv+code slice pairs) — plus three tightenings (per-request throughput definition, identical server flags across arms, trace-mirror substitution rule). A second protocol↔script reconciliation pass will run before the first measurement, per the standing procedure established in effiq/pilot001 DEVIATIONS.md.*

---

## Amendment Log

All amendments are: (a) made **before any formal measurement data was collected**; (b) justified by archived, hash-pinned evidence in `effiq/pilot-logs`; (c) signed by the project owner. The frozen sections above remain unchanged except as stated below.

### Amendment-01 · Offered-load thinning grid extension (2026-10-06)

**Change (L2):** the thinning retention grid **r ∈ {1, 1/2, 1/4, 1/8}** becomes **r ∈ {1, 1/2, 1/4, 1/8, 1/16, 1/32, 1/64, 1/128, 1/256}**. The selection rule is unchanged in kind: the heaviest configuration (largest r × C; ties toward larger C) at which Arm A attains ≥ 95% SLO compliance on the calibration slice pair; if no grid point passes, the lightest configuration (now r = 1/256, C = 4) is used and the shortfall is disclosed in the verdict. One operational clarification, pre-registered here: calibration scans configurations in strictly decreasing offered-load order and stops at the first pass — outcome-identical to a full grid scan under the documented assumption that SLO compliance is monotone non-increasing in offered load; every attempted configuration is recorded in the calibration log (watermarked CALIBRATION DATA ONLY).

**Justification (evidence: Stage-01 anchors, `effiq/pilot-logs` 2026-10-06/01-trace-pipeline/run_1, pushed at commit `4b23514`):** the selected formal slice pairs carry 108k–461k merged requests/hour; the raw traces average 282M (conv) + 253M (code) tokens/hour. A single L40S serving Qwen2.5-14B sustains on the order of 10M tokens/hour (Pilot 001 Stage-01 calibration measured 408–1176 tok/s total per request at batch 1; continuous batching lifts aggregate throughput by roughly an order of magnitude, not two). The raw arrival process is therefore ≈ 50× single-card capacity, and the lightest originally-frozen configuration (r = 1/8, C = 4 → 0.5× raw) is ≈ 25× over: the entire frozen grid would have measured collapse, not serving, and the fallback clause would have locked the pilot into that degenerate regime. The extension preserves the rule's intent — the heaviest honestly-servable load — while making the grid reachable. At r = 1/256 each formal run still carries ≈ 400–1,800 requests per arm block, ample for the paired statistics.

**Timing:** signed 2026-10-06, before any measurement data. Stage 01 is CPU-only trace processing; no GPU measurement has occurred in this window.

§2 exploration space item 1 is henceforth read with the extended grid.

*Signed by the operator, 2026-10-06.*
