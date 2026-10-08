# Pilot 002 — Reproduction Guide

Every verdict number in VERDICT.md is recomputed from the public log archive alone —
no GPU, no network services, no API keys. If you find a mismatch, that is a
reportable event; please open an issue.

## 0. Get the archive and the scripts

```bash
git clone https://github.com/effiq/pilot-logs.git     # all raw data + verdicts
git clone https://github.com/effiq/pilot002.git       # protocol + stage scripts
```

Requires: `bash`, `python3` (3.10+), `numpy` (`pip install numpy`). Nothing else.

## 1. Performance half (stage 04)

```bash
bash pilot002/stages/04-verdict.sh --verify pilot-logs/2026-10-08/04-verdict/run_1
```

Expected: the script recomputes the point estimate (2.3279×), the paired-bootstrap
95% CI ([1.6691, 4.1199]×, seed 20262002, 100,000 resamples), the secondary P95
gates, and all 12 block-hash cross-checks from the raw stage-03 archives, then prints:

```
VERIFY: verdict_p.txt / verdict_p.json identical (declared provenance fields normalized)
VERIFY: ALL CHECKS PASSED
```

Declared normalization (only these two machine-local provenance fields are excluded
from byte-comparison; every number is byte-compared): the absolute archive path in
the header, and `scripts_rev` (resolvable only where a pilot002 git checkout exists).

## 2. Quality half (stage 05)

```bash
bash pilot002/stages/05-quality-gate.sh --verify pilot-logs/2026-10-08/05-quality-gate/run_1
```

Expected: recomputation of all per-axis deltas, the overall delta (−0.036), the FAIL
criterion line, per-form deltas, and the descriptive CI from the archived
`judge_raw.jsonl` + `blind_map.jsonl` + generation logs, ending with:

```
VERIFY: verdict_q.txt byte-identical
VERIFY: ALL CHECKS PASSED
```

The verify path never calls a judge model and never touches a GPU; it re-derives the
verdict from the archived judge responses.

## 3. Judge-robustness addendum (stage 06, after it runs)

```bash
bash pilot002/stages/06-judge-robustness.sh --verify pilot-logs/<date>/06-judge-robustness/run_1
```

Same contract: recompute `verdict_jr.txt` / `verdict_jr.json` from the archived
panel judge log; the same two declared provenance fields are normalized.

## 4. Anchor hashes worth checking first

```bash
sha256sum pilot-logs/2026-10-08/05-quality-gate/run_1/frozen_set.jsonl
# 728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d
```

The frozen evaluation set is reused from Pilot 001 by hash; stage 05/06 refuse to run
against any input whose hash differs from the pre-registered anchors (gen_A
`16df35cc…`, gen_B `8e79384a…`, blind_map `684aea8d…`).

## 5. What reproduction does and does not cover

- Covered: every statistic and every verdict line, from archived raw logs.
- Not covered (by design): re-running the serving measurement itself (needs an L40S,
  ~4 h, and the frozen plan files whose hashes are anchored in the archive), and
  re-calling the judge endpoints (judge outputs are archived verbatim; live judges
  drift over time — see VERDICT.md §5).
