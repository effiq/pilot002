# Pilot 002 — Addendum-01, Amendment-01: Judge Script Patch (Null-Content Fix)

**Status:** FROZEN before re-execution. This amendment must be committed to the
public `effiq/pilot002` repository **before** the patched
`stages/06-judge-robustness.sh` is run. The original
`PREREG-ADDENDUM-01-judge-robustness.md` remains in force except as modified below.

- Date frozen: 2026-10-08 (UTC)
- Owner signature: ______________ (repo commit of this file constitutes the signature)
- New script anchor: `stages/06-judge-robustness.sh`
  sha256 = `2a21fecd1395419cdf5974d40f2ddaf12e1f3b2615450d322e0651ff6d4a8bb2`
  (**supersedes** `a302d7668584ddeb719bd9a9d1ccd62eb27ac8c3d49b2020f3a876daae7809e8`)

---

## 1. Trigger (incident record)

First execution attempt, 2026-10-08, run_1: panel probe selected `z-ai/glm-4.6` and
`deepseek/deepseek-v3.1-terminus` per the frozen order. The first judged item failed
repeatedly with `AttributeError: 'NoneType' object has no attribute 'strip'`:
`glm-4.6` is a reasoning-mode model and returned **null `content`** (the token budget
was consumed by internal reasoning). The run was stopped by the operator.

**Zero-data state at patch time (evidence):** the panel order judges glm-4.6 first;
every glm-4.6 call failed before any row was written, so `judge_raw_jr.jsonl` was
empty and no terminus judging had begun. No data of any kind was produced. The patch
therefore contaminates nothing.

## 2. Root cause

The candidate probe checked only that the `content` field *existed* in the response,
not that it contained text — so a reasoning-mode judge "passed" the probe while being
unable to deliver scoreable output. Same defect class as the stage-03 line-342
incident: an untested path surfaced on first contact with the real environment, at
zero cost, and is recorded rather than hidden.

## 3. Changes (complete list; nothing else changed)

1. API request body gains `"reasoning": {"exclude": true}` — asks the provider for
   direct output instead of spending the budget on internal reasoning; a no-op for
   non-reasoning models.
2. Probe hardened: a candidate whose probe response has empty/null content is
   **not "reachable"** and the probe falls through to the next frozen candidate.
   This refines the frozen phrase "first 2 reachable" — a judge that cannot emit
   text was never reachable for judging purposes.
3. Judging `max_tokens` 300 → 1024 (headroom; cost impact negligible, billed tokens
   are usage-based).
4. On a null-content judging response, the script now raises with the truncated raw
   response (200 chars) archived in the log, so future failures carry their own
   evidence.

The frozen panel candidate list and order, the reused blind map, the judging prompt
(byte-identical to stage 05), the decision rules (ROBUST-FAIL / ROBUST-CLEAR /
MIXED), all thresholds, seeds, anchors, and guards are **unchanged**.

## 4. Consequence for interpretation

If `glm-4.6` responds with real content under `reasoning.exclude`, it remains panel
judge #1 per the frozen order. If it still returns null content, the hardened probe
marks it unreachable and the panel becomes `deepseek-v3.1-terminus` +
`deepseek-chat-v3.1` — in which case the panel is all-DeepSeek-family, and the
family-overlap limitation declared in the original pre-registration becomes the
operative caveat. Both branches are pre-registered here; neither requires further
amendment.
