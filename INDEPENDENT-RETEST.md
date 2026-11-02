# Independent Verification & Re-Measurement — Pilot 002

This repository ships with its complete verdict evidence bundled under `retest/`.
You can check every published number yourself, with no account, no API key, and
no assistance from us. Two tracks are offered:

- **Track 1 — audit / recompute** (no GPU): re-derive the verdict from the
  bundled raw archives, byte-for-byte.
- **Track 2 — independent re-measurement** (one rented GPU): re-run the
  measurement under the same protocol on your own hardware and compare against
  the pre-registered pass criteria.

Pilot 002's verdict is deliberately two-sided: performance **PASS**
(2.3279×, 95% CI [1.6691, 4.1199]) and quality **FAIL** (clarity delta −0.127
vs tolerance −0.1). Both halves are published as measured. A failed half is
not a defect of the archive — it is the pre-registered rule firing on the
result we were hoping would pass.

---

## Track 1 — audit / recompute (no GPU)

Requirements: `bash`, `python3` ≥ 3.10 with `numpy`. No network beyond the
initial clone.

```bash
mkdir -p ~/effiq && cd ~/effiq
git clone https://github.com/effiq/pilot002.git
ln -s "$HOME/effiq/pilot002/retest/pilot-logs" ~/effiq/pilot-logs
```

### Performance half (stage 04)

```bash
bash ~/effiq/pilot002/stages/04-verdict.sh --verify ~/effiq/pilot-logs/2026-10-08/04-verdict/run_1
```

Expected ending: recomputed point estimate 2.3279×, CI [1.6691, 4.1199]
(seed 20262002, 100,000 resamples), both P95 secondary gates, 12 block-hash
cross-checks, then:

```
VERIFY: verdict_p.txt / verdict_p.json identical (declared provenance fields normalized)
VERIFY: ALL CHECKS PASSED
```

### Quality half (stage 05)

```bash
bash ~/effiq/pilot002/stages/05-quality-gate.sh --verify ~/effiq/pilot-logs/2026-10-08/05-quality-gate/run_1
```

Expected: all per-axis deltas recomputed (overall delta −0.036; clarity −0.127
vs tolerance −0.1 → FAIL), ending with:

```
VERIFY: verdict_q.txt byte-identical
VERIFY: ALL CHECKS PASSED
```

### Judge-robustness addendum (stage 06)

```bash
bash ~/effiq/pilot002/stages/06-judge-robustness.sh --verify ~/effiq/pilot-logs/2026-10-08/06-judge-robustness/run_1
```

Expected ending: `VERIFY: ALL CHECKS PASSED`.

### Integrity

```bash
cd ~/effiq/pilot002/retest && sha256sum -c MANIFEST.sha256
```

---

## Track 2 — independent re-measurement (rented GPU)

Both arms are stock configurations (BF16 defaults vs vLLM built-in FP8 dynamic
quantization), and the workload replays the Azure LLM Inference Trace 2024,
which is a public dataset (CC-BY). Every input is obtainable by anyone.

1. Rent one NVIDIA L40S 48GB.
2. Install the pinned stack from `retest/environment.lock`.
3. Clone this repo to `~/effiq/pilot002` and run the stage sequence in fresh
   measurement mode — each stage writes its own logs:

   ```bash
   bash ~/effiq/pilot002/stages/01-trace-pipeline.sh   # downloads + slices the public trace (CPU only)
   bash ~/effiq/pilot002/stages/02-calibration.sh      # finds the operating point (GPU)
   bash ~/effiq/pilot002/stages/03-formal.sh           # six formal runs (GPU, hours)
   bash ~/effiq/pilot002/stages/04-verdict.sh          # computes the performance verdict
   ```

   Stage 01 is deterministic: same trace + same seed (20261010) must reproduce
   the published slice manifests hash-for-hash — the expected hashes are in the
   bundled archive under `2026-10-08/01-trace-pipeline/`.
4. Compare against the pre-registered criteria (CI lower bound ≥ 1.20×;
   P95 secondary gates ≤ 1.05×), not against our point estimates to the last
   decimal.

The quality half uses third-party judge models via API; re-running it requires
your own API access, and judge drift applies — see the Pilot 001 retest guide
for the full caveat.

Trace sources (also embedded in `stages/01-trace-pipeline.sh`):
`https://github.com/Azure/AzurePublicDataset/releases/download/dataset-llm-2024/AzureLLMInferenceTrace_conv_1week.csv`
and `…_code_1week.csv`.
