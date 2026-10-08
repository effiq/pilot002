# Pilot 002 — Addendum-01: Judge-Robustness Probe (Pre-Registration)

**Status:** FROZEN before execution. This document must be committed to the public
`effiq/pilot002` repository **before** `stages/06-judge-robustness.sh` is run against
the real judge endpoints. Any change to the rules below after execution begins
invalidates the addendum and requires a new pre-registration.

- Date frozen: 2026-10-08 (UTC)
- Owner signature: ______________ (repo commit of this file constitutes the signature)
- Script anchor: `stages/06-judge-robustness.sh`
  sha256 = `a302d7668584ddeb719bd9a9d1ccd62eb27ac8c3d49b2020f3a876daae7809e8`

---

## 1. Question

Stage 05 (sealed verdict: FAIL) found a clarity-axis breach of the FP8 arm
(delta = −0.127 vs the pre-registered tolerance of −0.1, 10-pt scale), scored by a
single judge (`deepseek/deepseek-chat-v3-0324`). Post-hoc analysis (VERDICT.md §6)
showed the breach margin (0.027) is smaller than the observed day-to-day drift of
that same judge (0.67–0.91 points on identical arm-A material between Pilot 001 and
Pilot 002), and that per-item score deltas correlate at −0.002 across pilots.

**Pre-registered question:** does the clarity-axis breach replicate when an
independent judge panel scores the *same archived outputs*, or is it consistent
with single-judge noise?

## 2. Explicit Non-Goals

- This addendum **does not modify, overturn, or re-open the sealed stage-05 verdict
  (FAIL)**. Pilot 002's headline result stands regardless of the panel outcome.
- No new model outputs are generated. No GPU is used. The only new data are judge
  scores on already-archived texts.
- This is not a search for a friendlier judge. The panel selection rule below is
  mechanical and frozen.

## 3. Data (sealed inputs, hash-anchored)

All inputs are read-only artifacts of the sealed stage-05 run
(`2026-10-08/05-quality-gate/run_1` in the public `effiq/pilot-logs` archive),
verified by sha256 before any judging:

| artifact | sha256 |
|---|---|
| frozen_set.jsonl | `728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d` |
| gen_A.jsonl | `16df35ccad32cc60a5785ce87fa96e325487b66ec3000e3fa04e6479b886c8cd` |
| gen_B.jsonl | `8e79384a6c3a621d532dec4304da0c5a3fed960a256c606794e6135a0d9ba57c` |
| blind_map.jsonl | `684aea8dcc33ce4f88d9aa8644007cdb8ace0e4ff331a124b8c62fe1c7e76392` |

The script refuses to run if any anchor mismatches. The blind map is **reused**:
every panel judge sees the identical response-1/response-2 presentation order the
original judge saw. No new randomness enters item presentation.

## 4. Panel Selection (mechanical, frozen)

Probe the following candidates **in this order**; the first **2** that respond to a
trivial probe become the panel:

1. `z-ai/glm-4.6`
2. `deepseek/deepseek-v3.1-terminus`
3. `deepseek/deepseek-chat-v3.1`

If fewer than 2 candidates are reachable, the probe **refuses** (no partial panel;
owner decision required).

Carried-over judge policy (unchanged from stage 05 / Pilot 001):
OpenAI/Anthropic/Google models are unreachable from this account's billing region;
Qwen-family judges are excluded by design (family conflict of interest — the
evaluated outputs are Qwen2.5-14B-Instruct); the original judge
`deepseek/deepseek-chat-v3-0324` is excluded from the panel (it already produced
the sealed verdict).

**Declared limitation:** candidates #2/#3 share the DeepSeek family with the
original judge, so panel independence is partial. The robustness question is about
judge-instance replication, and the observed same-family day-to-day drift is itself
larger than the breach margin — family overlap does not invalidate the probe, and
this limitation is stated rather than hidden.

## 5. Procedure

- Judging prompt (system + user template) is **byte-identical** to the stage-05
  judge phase (see `stages/05-quality-gate.sh`); temperature 0; retries 5/15/30 s;
  raw judge responses archived per row.
- All 150 frozen items are judged by each panel judge (300 rows total).
- Budget guard: USD 5 (expected actual < USD 1). Time guard: 7200 s.
- Resume-safe: re-running the same command continues the append-only judge log;
  judged rows are never re-judged.

## 6. Analysis Rules (frozen)

Per panel judge, computed with the same math as stage 05:

- per-axis deltas (B − A) over 150 items, on the three frozen axes;
- overall pooled delta and the stage-05 pass/fail criterion
  (overall ≥ −0.1 AND every axis ≥ −0.1), reported per judge;
- descriptive 95% bootstrap CI of the clarity delta (seed 20261012,
  100,000 resamples; same seed reused for each judge, declared).

**Panel outcome (the only pre-registered decision):**

| outcome | rule |
|---|---|
| ROBUST-FAIL | every panel judge breaches the clarity axis (delta < −0.1) |
| ROBUST-CLEAR | every panel judge is within tolerance on the clarity axis |
| MIXED | otherwise |

All outcomes are publishable and will be published as-is. A ROBUST-CLEAR outcome
does **not** convert the sealed FAIL into a PASS; it classifies the breach as
judge-fragile, which is input to future engineering decisions (e.g., whether a
multi-judge gate is warranted in future protocols), not a retrial.

## 7. Reproducibility

`bash stages/06-judge-robustness.sh --verify <run_dir>` recomputes
`verdict_jr.txt` / `verdict_jr.json` from the archived logs alone (no network, no
GPU) and byte-compares, with two declared machine-local provenance fields
normalized (source-archive path, scripts_rev).

## 8. Interpretation Contract

- ROBUST-FAIL → the clarity signal is real at judge level; engineering follow-ups
  (operating-point mapping, recipe revision) become the priority.
- ROBUST-CLEAR → the breach is consistent with single-judge noise; the honest
  public statement remains "quality neutrality not demonstrated at this operating
  point", with the addendum quantifying how judge-dependent that statement is.
- MIXED → unresolved; stated as unresolved. No further judging rounds will be
  appended to this addendum.
