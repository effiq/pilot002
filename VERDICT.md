# Pilot 002 — Verdict

**FP8 dynamic quantization vs BF16, replayed production traffic, pre-registered statistics.**

| half | result | headline number |
|---|---|---|
| Performance | **PASS** | per-request throughput ratio **2.3279×**, paired-bootstrap 95% CI **[1.6691, 4.1199]×** |
| Quality | **FAIL** | clarity-axis delta **−0.127** vs pre-registered tolerance −0.1 (10-pt blind-judge scale) |

**Combined claim — "FP8 at this operating point is both faster and quality-neutral" —
does NOT hold.** The performance gain is real and large; quality neutrality was not
demonstrated. Both halves are published as measured, with raw logs, in the public
`effiq/pilot-logs` archive. The quality FAIL was produced by the pre-registered rule
firing against the result we were hoping for; it is reported unchanged.

---

## 1. Setup

| | |
|---|---|
| Model | Qwen/Qwen2.5-14B-Instruct @ `cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8` |
| Serving stack | vLLM 0.31.0 (pinned), single NVIDIA L40S, max_model_len 32768 |
| Arm A | BF16 defaults, prefix caching off |
| Arm B | FP8 dynamic quantization (vLLM built-in), identical serving config |
| Traffic | Azure LLM Inference Trace 2024 (conversation + code services); 6 hour-aligned window pairs + 1 calibration pair, seed 20261010 |
| Design | block-interleaved arms (odd/even runs alternate which arm starts), request-level pairing by request_id within run |
| Protocol | Protocol Lock v2.1, frozen 2026-10-06 (repo commit `49277e2`), Amendment-01 `9dc7af3` (subsampling grid extended to r = 1/256 after stage-01 capacity measurement, signed before any serving measurement) |
| Operating point | calibration-derived; the calibration night hit the declared fallback (no grid configuration met the SLO on the heaviest hours) — fallback operating point was used and is disclosed in every stage banner |

Scale note: the raw trace carries ≈ 50× the capacity of a single L40S at its busiest
hour; per Amendment-01 the replay uses pre-registered thinning/compression, so absolute
rates are scaled but both arms see byte-identical arrival patterns.

## 2. Performance half (stage 03 measurement → stage 04 sealed verdict)

- Primary statistic (pre-registered): per-request throughput (completion tokens /
  end-to-end seconds, queueing included), paired within run → run-level mean
  log-ratio → paired bootstrap over 6 runs, seed 20262002, 100,000 resamples.
  **Point estimate 2.3279×; 95% CI [1.6691, 4.1199]×; PASS rule exp(CI lower) ≥ 1.20 → PASS.**
- Run-level mean log-ratios: +0.4541 / +0.5057 / +2.2380 / +0.5967 / +0.7240 / +0.5511
  (13,104 measured requests; pair counts 459/794/1754/1209/1390/946).
- Secondary gates (each must be ≤ 1.05×): pooled P95 TPOT ratio B/A = **0.6846**,
  pooled P95 TTFT ratio B/A = **0.0499** — clean, with margin.
- The tail is the story: pooled P95 TTFT is **37.272 s on BF16 vs 1.861 s on FP8**.
  On the heaviest hour pair, BF16 saturates (mean 1.60 req/s served) while FP8 holds
  (9.07 req/s) — the run-3 log-ratio of +2.2380 is the capacity knee, not an outlier.

## 3. Quality half (stage 05 sealed verdict)

- Frozen evaluation set (150 items, hash `728b2f83…5cf7d`, reused from Pilot 001),
  generated serving-mode at concurrency 8, temperature 0, natural stopping.
- Blind judging: judge never sees arm labels; blind map seed 20261011;
  judge `deepseek/deepseek-chat-v3-0324`; 150/150 judged; raw responses archived.

| axis | A (BF16) | B (FP8) | delta |
|---|---|---|---|
| correctness | 7.160 | 7.173 | +0.013 |
| instruction_following | 6.940 | 6.947 | +0.007 |
| clarity | 6.733 | 6.607 | **−0.127** |

Overall pooled delta −0.036. Criterion (pre-registered): overall ≥ −0.1 AND every
axis ≥ −0.1 → **FAIL** (clarity breaches by 0.027). Descriptive bootstrap CI of the
overall delta [−0.329, +0.260] crosses zero; per protocol the gate uses point
estimates. Per-form pooled deltas: doc_qa +0.180, code_completion −0.080,
summarization −0.207. The two arms produced textually identical outputs on 0/150 items.

## 4. What this means, stated precisely

- **Supported:** FP8 delivers a large, statistically sealed throughput advantage
  under replayed production load at this operating point, with dramatically better
  tail latency.
- **Not demonstrated:** quality neutrality at this operating point. One axis of one
  blind judge breached tolerance by 0.027.
- **Not supported (and not claimed):** "FP8 degrades quality." The breach margin is
  below the judge's own observed drift (§5), the descriptive CI crosses zero, and
  per-item damage shows no stable signature. The honest statement is "quality
  neutrality not demonstrated," nothing stronger in either direction.

## 5. Post-hoc exploratory analysis (descriptive; NOT part of the verdict)

Computed after the sealed verdict, on public archive data only; reported because it
shapes how a reader should weigh §3:

1. **Judge drift:** the same judge model scored the *same arm-A material* (same model,
   same 150 prompts) 0.67–0.91 points higher across all axes in Pilot 002 than in
   Pilot 001. The within-pilot B−A design absorbs this drift by construction; the
   absolute scale does not.
2. **No stable per-item signature:** items losing clarity points in Pilot 002 are not
   the items that lost points in Pilot 001 (per-item delta correlation −0.002).
3. **Breadth, not catastrophe:** 78/150 items lost one clarity point each; the worst
   single-item delta is −4 (3 items).
4. **Weak form-level consistency:** summarization clarity deltas were negative in both
   pilots (−0.200 / −0.280), while doc_qa and code_completion flipped sign across
   pilots (Pilot 001: −0.440 / +0.800).

A pre-registered follow-up (`PREREG-ADDENDUM-01-judge-robustness.md`) re-judges the
same archived outputs with an independent judge panel to classify the breach as
judge-robust or judge-fragile. Its outcome will be published as an addendum whatever
it shows.

## 6. Governance chain and incidents

- Protocol Lock v2.1 frozen at commit `49277e2` (2026-10-06); Amendment-01 `9dc7af3`
  signed after stage-01 capacity measurement, before any serving data existed.
- Log chain (public `effiq/pilot-logs`): stage 01 `a3ab38c..4b23514`, stage 02/03
  through `877d06c`, stage 04 `877d06c..d1489e2`, stage 05 `8e0aeb4..ac27089`.
- **Incident disclosures (all in the archive):**
  - stage-03 script crashed on first production run (bash `set -u` interaction in one
    helper); root-caused, patched (`6f27d3e4…`), harness-tested, rerun — the crash hit
    an honestly-declared test-gap path at zero GPU cost.
  - stage-04 `--verify` initially failed byte-comparison across machines because two
    machine-local provenance fields were embedded in compared artifacts; patched with
    declared normalization (`71a4930f…`); every verdict number remained byte-exact.
  - stage-05 first pod died at engine init (host NVIDIA driver too old for the pinned
    torch cu130 build); zero data produced; pod swapped, driver check added to the
    human runbook; script unchanged.
- All verdicts are byte-reproducible from the public archive alone (see REPRODUCE.md).

## 7. Related work

- **Pareto Atlas** (arXiv:2609.17863) maps which inference optimizations dominate the
  cost-quality-latency frontier across models/hardware via measured anchors plus a
  calibrated simulator. Complementary and concurrent: it maps *which* configurations
  are worth choosing; we measure *one* configuration end-to-end on replayed production
  traffic with pre-registered inferential statistics and a blind quality gate.
- **Cascade** (arXiv:2608.06557) is a serving *scheduler* (per-request latency
  budgets) reporting up to 2.4× goodput on production traces. Orthogonal lever: it
  changes scheduling, not weight precision; both could stack.
- **SPEED-Bench** (arXiv:2604.09557) standardizes speculative-decoding evaluation.
  Same family of concern (faithful speedup measurement), different optimization.
- To our knowledge, the intersection "production-trace replay × weight quantization ×
  pre-registered paired statistics with a blind quality gate and public raw logs"
  remains empty. That is the gap this pilot occupies; it is also why our result does
  not contradict single-number quantization benchmarks — it measures a different
  thing.

## 8. Scope and limitations

Single model (Qwen2.5-14B), single GPU class (L40S), single serving stack (vLLM
0.31.0), one operating point on one trace family; payload contents are synthetic
fillers shaped to trace token counts (declared since Pilot 001); quality judged by
LLM judges on a 150-item frozen set (judge noise quantified in §5); trace thinned
per pre-registered rule (absolute rates scaled, not raw production QPS). Nothing in
this document should be read as a claim about other models, GPUs, quantizers, or
operating points.

## 9. Hash manifest (short form)

| artifact | sha256 (prefix) |
|---|---|
| stage-04 verdict script | `71a4930f…f87c1d` |
| stage-05 quality-gate script | `ab8c4c58…c8a9a5` |
| stage-06 judge-robustness script (addendum) | `a302d766…7809e8` |
| frozen_set.jsonl | `728b2f83…5cf7d` |
| stage-05 gen_A / gen_B | `16df35cc…` / `8e79384a…` |
| stage-05 blind_map / judge_raw | `684aea8d…` / `2404eca1…` |
| verdict_p.txt / verdict_q.txt | in archive `2026-10-08/04-verdict/run_1`, `2026-10-08/05-quality-gate/run_1` |

Full hashes live in the public archive; every number in this document is recomputed
by the `--verify` entry points described in REPRODUCE.md.
