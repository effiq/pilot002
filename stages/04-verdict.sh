#!/usr/bin/env bash
# ============================================================
# Stage 04 · L4 sealed verdict (Pilot 002)
#
# This script is the ONLY place where the primary statistic's
# confidence interval is computed (Protocol Lock v2.1, L4):
#
#   Primary statistic: per-request throughput
#     tps = completion_tokens / e2e_s   (queue wait included)
#   Per run: pair arms by request_id, log-ratio per pair,
#     run-level value = mean of per-pair log-ratios.
#   Across runs: paired bootstrap over run-level values
#     (n = number of formal runs present; 100,000 resamples;
#     bootstrap seed 20262002 — fully deterministic).
#   PASS ⟺ exp(CI lower bound) ≥ 1.20. Otherwise FAIL.
#   If the CI straddles 1.20 at n = 6, runs may extend to 10 per
#   the pre-registered rule — never more. Extension requires the
#   owner-signed slice-assignment decision (reconciliation open
#   item, RECONCILIATION-stage03.md §4); this script declares the
#   straddle and stops. At n = 10 the straddle escape is
#   exhausted and the lower-bound rule decides.
#
#   Secondary gate (pre-registered, tail-latency non-inferiority):
#   on pooled formal-run requests, P95 TPOT and P95 TTFT of arm B
#   must each not exceed arm A's by more than 5%. A breach is FAIL
#   regardless of the primary statistic (and forecloses extension).
#
# Seal discipline (L4 anti-p-hacking): the CI is computed only
# after the stage-03 COMPLETE marker exists; descriptive means
# during the window are not the verdict. This script recomputes
# EVERYTHING from the raw per-request JSONL archives — summaries
# and markers are cross-checked, never trusted.
#
# Fallback disclosure (L2 / Amendment-01): stage 02 found no grid
# configuration meeting the SLO; the lightest configuration was
# used and the shortfall is carried into the verdict text.
#
# CPU-only. No GPU, no network. Runs anywhere the logs repo is
# cloned.
#
# Verify entry: bash stages/04-verdict.sh --verify [run_dir]
# Recomputes the verdict from the stage-03 raw archives and
# byte-compares against the archived verdict_p.txt.
#
# Test hooks (sandbox only, never set in production):
#   LOGS_DIR, STAGE04_OUT_DIR, STAGE04_FORCE_VERIFY_ONLY
# ============================================================
set -euo pipefail

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot002}"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE_SRC="03-formal"
STAGE_NAME="04-verdict"

THRESH=1.20                  # L4: PASS ⟺ exp(CI lower) ≥ 1.20
BOOT_SEED=20262002           # L4: pinned bootstrap seed
BOOT_N=100000                # L4: pinned resample count
N_BASE=6                     # L4: formal runs before any extension
N_MAX=10                     # L4: extension ceiling — never more
P95_TOL=1.05                 # L4: secondary gate, tail-latency non-inferiority

say()  { printf '\n\033[1;36m[stage04] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[stage04][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------- locate stage-03 archive (seal check) ----------------
SRC_DIR="$(ls -dt "$LOGS_DIR"/*/"$STAGE_SRC"/run_* 2>/dev/null | head -1 || true)"
[ -n "$SRC_DIR" ] || die "no stage-03 archive found under $LOGS_DIR — run stage 03 first"

# ---------------- chosen.json (fallback disclosure) ----------------
CHOSEN_JSON=""
for d in $(ls -dt "$LOGS_DIR"/*/02-calibration/run_* 2>/dev/null); do
  [ -f "$d/chosen.json" ] && CHOSEN_JSON="$d/chosen.json" && break
done
[ -n "$CHOSEN_JSON" ] || die "chosen.json not found — stage 02 archive incomplete"

# ---------------- --verify ----------------
# Recompute the verdict from the raw stage-03 archives into a temp dir and
# byte-compare both verdict files against the archive. No network, no GPU.
if [ "${1:-}" = "--verify" ]; then
  VD="${2:-}"
  if [ -z "$VD" ]; then VD="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$VD" ] && [ -f "$VD/verdict_p.txt" ] || die "--verify: no verdict archive found (usage: --verify [run_dir])"
  say "--verify: recomputing from $SRC_DIR and comparing against $VD"
  SELF="$(readlink -f "$0")"
  TMPD="$(mktemp -d)"
  STAGE04_OUT_DIR="$TMPD" STAGE04_FORCE_VERIFY_ONLY=1 bash "$SELF" > /dev/null
  # Every NUMBER is compared byte-exactly. Two provenance fields are
  # machine-local by nature and are normalized before comparison (declared):
  #   - the absolute archive path in "computed from raw archives: ..."
  #   - scripts_rev (resolves only where a pilot002 git checkout exists)
  SRC_DIR="$SRC_DIR" LOGS_DIR="$LOGS_DIR" VD="$VD" TMPD="$TMPD" python3 - <<'PY'
import json, os, re, sys
VD, TMPD = os.environ["VD"], os.environ["TMPD"]
rel = os.path.relpath(os.environ["SRC_DIR"], os.environ["LOGS_DIR"])
def norm_txt(p):
    t = open(p).read()
    t = re.sub(r"computed from raw archives: \S+", f"computed from raw archives: {rel}", t)
    t = re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
    return t
a, b = norm_txt(os.path.join(VD, "verdict_p.txt")), norm_txt(os.path.join(TMPD, "verdict_p.txt"))
if a != b:
    sys.exit("VERIFY: verdict_p.txt MISMATCH (after declared provenance normalization)")
ja = json.load(open(os.path.join(VD, "verdict_p.json")))
jb = json.load(open(os.path.join(TMPD, "verdict_p.json")))
for j in (ja, jb):
    j.pop("scripts_rev", None); j.pop("source_archive", None)
if ja != jb:
    diff = {k for k in set(ja) | set(jb) if ja.get(k) != jb.get(k)}
    sys.exit(f"VERIFY: verdict_p.json MISMATCH in fields: {sorted(diff)}")
print("VERIFY: verdict_p.txt identical (numbers byte-exact; machine-local provenance normalized)")
print("VERIFY: verdict_p.json identical (all numeric/verdict fields equal)")
PY
  say "VERIFY: ALL CHECKS PASSED"
  rm -rf "$TMPD"
  exit 0
fi

# ---------------- seal: refuse until stage 03 is COMPLETE ----------------
[ -f "$SRC_DIR/COMPLETE" ] || die "SEALED: stage 03 has no COMPLETE marker ($SRC_DIR) — the CI stays sealed until all formal runs are archived (L4 anti-p-hacking)"

# ---------------- COMPLETE guard (idempotent re-entry) ----------------
LATEST_OUT="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
if [ -z "${STAGE04_FORCE_VERIFY_ONLY:-}" ] && [ -z "${STAGE04_OUT_DIR:-}" ] && [ -n "$LATEST_OUT" ] && [ -f "$LATEST_OUT/COMPLETE" ]; then
  say "this stage is already COMPLETE — verdict preserved at:"
  echo "  $LATEST_OUT/verdict_p.txt"
  echo "  (to recompute from the raw archives: bash stages/04-verdict.sh --verify)"
  exit 0
fi

# ---------------- output dir ----------------
if [ -n "${STAGE04_OUT_DIR:-}" ]; then
  OUT_DIR="$STAGE04_OUT_DIR"; mkdir -p "$OUT_DIR"
else
  BASE="$LOGS_DIR/$DATE_STR/$STAGE_NAME"; mkdir -p "$BASE"
  N=1; while [ -e "$BASE/run_$N" ]; do N=$((N+1)); done
  OUT_DIR="$BASE/run_$N"; mkdir -p "$OUT_DIR"
fi

GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
python3 -c "import numpy" 2>/dev/null || pip install -q numpy   # bootstrap dependency
say "computing the sealed verdict from $SRC_DIR (scripts_rev=$GIT_REV)"

SRC_DIR="$SRC_DIR" CHOSEN_JSON="$CHOSEN_JSON" OUT_DIR="$OUT_DIR" \
THRESH="$THRESH" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" \
N_BASE="$N_BASE" N_MAX="$N_MAX" P95_TOL="$P95_TOL" GIT_REV="$GIT_REV" \
STAGE_NAME="$STAGE_NAME" python3 - <<'PY'
import glob, hashlib, json, math, os, statistics, sys

SRC     = os.environ["SRC_DIR"]
OUT     = os.environ["OUT_DIR"]
THRESH  = float(os.environ["THRESH"])
BSEED   = int(os.environ["BOOT_SEED"])
BN      = int(os.environ["BOOT_N"])
N_BASE  = int(os.environ["N_BASE"])
N_MAX   = int(os.environ["N_MAX"])
P95TOL  = float(os.environ["P95_TOL"])
GREV    = os.environ["GIT_REV"]

chosen = json.load(open(os.environ["CHOSEN_JSON"]))
DISCLOSURE = ("no grid configuration met the SLO; lightest configuration used, "
              "shortfall disclosed per protocol")
FB = bool(chosen.get("fallback"))

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

# ---------- load raw archives; cross-check markers, never trust them ----------
runs = {}   # run_idx -> {"A": {rid: row}, "B": {rid: row}, "pair": str}
integrity = []
for rd in sorted(glob.glob(os.path.join(SRC, "formal_run_*")),
                 key=lambda p: int(p.rsplit("_", 1)[1])):
    i = int(rd.rsplit("_", 1)[1])
    arms = {}
    pair = None
    for arm in ("A", "B"):
        fp = os.path.join(rd, f"arm{arm}.jsonl")
        mp = os.path.join(rd, f"arm{arm}.done")
        if not (os.path.exists(fp) and os.path.exists(mp)):
            sys.exit(f"FATAL: run {i} arm {arm} missing jsonl or .done marker — archive incomplete")
        marker = json.load(open(mp))
        actual = sha(fp)
        integrity.append((f"run {i} arm {arm}", marker.get("raw_sha256", "") == actual,
                          f"{actual[:16]}…"))
        rows = {}
        for line in open(fp):
            r = json.loads(line)
            if "status" not in r:
                pair = pair or r.get("pair_id")
                continue                      # header line
            if r["status"] == "ok":
                rows[r["request_id"]] = r
        arms[arm] = rows
    runs[i] = {"A": arms["A"], "B": arms["B"], "pair": pair}

bad = [n for n, ok, _ in integrity if not ok]
if bad:
    sys.exit(f"FATAL: raw archive hash mismatch vs block markers: {bad}")

n_runs = len(runs)
if n_runs < N_BASE:
    sys.exit(f"FATAL: only {n_runs} complete runs — need {N_BASE}")
if n_runs > N_MAX:
    sys.exit(f"FATAL: {n_runs} runs present — L4 caps the extension at {N_MAX}")

# ---------- primary statistic (L4, exact) ----------
run_vals, pair_counts, excluded = [], [], 0
for i in sorted(runs):
    A, B = runs[i]["A"], runs[i]["B"]
    common = sorted(set(A) & set(B))
    excluded += (len(A) - len(common)) + (len(B) - len(common))
    lrs = [math.log((B[r]["completion_tokens"] / B[r]["e2e_s"]) /
                    (A[r]["completion_tokens"] / A[r]["e2e_s"])) for r in common]
    run_vals.append(statistics.mean(lrs))
    pair_counts.append(len(common))

import numpy as np
vals = np.array(run_vals)
point = float(vals.mean())
rng = np.random.default_rng(BSEED)
means = rng.choice(vals, size=(BN, len(vals)), replace=True).mean(axis=1)
lo, hi = (float(x) for x in np.percentile(means, [2.5, 97.5]))
e_lo, e_hi, e_pt = math.exp(lo), math.exp(hi), math.exp(point)

# ---------- secondary gate: pooled P95 non-inferiority ----------
def p95(v):
    v = sorted(v); k = (len(v) - 1) * 0.95
    f = math.floor(k); c = math.ceil(k)
    return v[f] if f == c else v[f] + (v[c] - v[f]) * (k - f)

pool = {"A": {"ttft": [], "tpot": []}, "B": {"ttft": [], "tpot": []}}
for i in runs:
    for arm in ("A", "B"):
        for r in runs[i][arm].values():
            pool[arm]["ttft"].append(r["ttft_s"])
            pool[arm]["tpot"].append(r["tpot_ms"])
p95_tpot = {a: p95(pool[a]["tpot"]) for a in ("A", "B")}
p95_ttft = {a: p95(pool[a]["ttft"]) for a in ("A", "B")}
tpot_ratio = p95_tpot["B"] / p95_tpot["A"]
ttft_ratio = p95_ttft["B"] / p95_ttft["A"]
secondary_ok = tpot_ratio <= P95TOL and ttft_ratio <= P95TOL

# ---------- verdict logic (L4) ----------
log_t = math.log(THRESH)
if lo >= log_t:
    primary = "PASS"
elif hi < log_t or n_runs >= N_MAX:
    primary = "FAIL"
else:
    primary = "STRADDLE"

if primary == "STRADDLE" and secondary_ok:
    verdict = "STRADDLE"
elif primary == "PASS" and secondary_ok:
    verdict = "PASS"
else:
    verdict = "FAIL"

# ---------- report ----------
L = []
L.append("STAGE 04 VERDICT — PILOT 002 PERFORMANCE HALF (L4)")
L.append(f"computed from raw archives: {SRC}")
L.append(f"scripts_rev={GREV}  bootstrap seed={BSEED}  resamples={BN}  threshold={THRESH}x")
if FB:
    L.append(f"disclosure: {DISCLOSURE} (operating point r=1/{chosen['D']}, C={chosen['C']})")
L.append("")
L.append("[input integrity] per-block raw JSONL sha256 vs stage-03 markers:")
for name, ok, short in integrity:
    L.append(f"  {name}: {'OK' if ok else 'MISMATCH'} ({short})")
L.append("")
L.append(f"[runs] n={n_runs} formal runs; paired requests per run: {pair_counts}"
         + (f"; unpaired rows excluded: {excluded}" if excluded else ""))
L.append("")
L.append("[primary] per-request throughput = output tokens / end-to-end latency (queue included)")
L.append("  run-level mean log-ratios (B/A): " + ", ".join(f"run {i}: {v:+.4f}" for i, v in zip(sorted(runs), run_vals)))
L.append(f"  point estimate: exp(mean) = {e_pt:.4f}x")
L.append(f"  paired bootstrap 95% CI (over runs): exp([{lo:+.4f}, {hi:+.4f}]) = [{e_lo:.4f}, {e_hi:.4f}]x")
L.append(f"  rule: PASS iff CI lower bound >= {THRESH}x  ->  primary = {primary}")
L.append("")
L.append("[secondary] pooled tail-latency non-inferiority (tolerance 5%)")
L.append(f"  P95 TPOT: A={p95_tpot['A']:.2f}ms B={p95_tpot['B']:.2f}ms ratio={tpot_ratio:.4f}  {'OK' if tpot_ratio <= P95TOL else 'BREACH'}")
L.append(f"  P95 TTFT: A={p95_ttft['A']:.3f}s B={p95_ttft['B']:.3f}s ratio={ttft_ratio:.4f}  {'OK' if ttft_ratio <= P95TOL else 'BREACH'}")
L.append("")
if verdict == "STRADDLE":
    L.append(f"STATUS: STRADDLE — the CI [{e_lo:.4f}, {e_hi:.4f}]x straddles {THRESH}x at n={n_runs}.")
    L.append("Per L4, runs may extend to 10 — never more. Extension requires the owner-signed")
    L.append("slice-assignment decision (reconciliation open item). Proposal: run 6+k replays")
    L.append("slice pair k (k=1..4), same arm-order parity rule. No verdict is rendered; the")
    L.append("performance half stays open until the signed decision exists and the extension")
    L.append("runs are archived. The secondary gate is clean, so extension remains legal.")
else:
    L.append(f"VERDICT (performance half): {verdict}")
    if verdict == "FAIL" and primary != "FAIL":
        L.append("  (primary statistic passed; the secondary tail-latency gate decided otherwise)")
L.append("")
L.append("Reproduce: bash stages/04-verdict.sh --verify")

txt = "\n".join(L) + "\n"
open(os.path.join(OUT, "verdict_p.txt"), "w").write(txt)

machine = dict(
    stage="04-verdict", pilot="002", scripts_rev=GREV,
    source_archive=SRC, n_runs=n_runs, pair_counts=pair_counts,
    excluded_unpaired_rows=excluded,
    run_mean_log_ratios={str(i): v for i, v in zip(sorted(runs), run_vals)},
    bootstrap=dict(seed=BSEED, resamples=BN, over="run-level mean log-ratios"),
    point_estimate_ratio=e_pt, ci95_log=[lo, hi], ci95_ratio=[e_lo, e_hi],
    threshold=THRESH, primary=primary,
    secondary=dict(p95_tpot_ms=p95_tpot, p95_ttft_s=p95_ttft,
                   tpot_ratio=tpot_ratio, ttft_ratio=ttft_ratio,
                   tolerance=P95TOL, ok=secondary_ok),
    fallback=FB, disclosure=DISCLOSURE if FB else None,
    verdict=verdict,
    input_sha256={f"run{i}_arm{a}": sha(os.path.join(SRC, f"formal_run_{i}", f"arm{a}.jsonl"))
                  for i in sorted(runs) for a in ("A", "B")},
)
open(os.path.join(OUT, "verdict_p.json"), "w").write(json.dumps(machine, indent=2, sort_keys=True) + "\n")
print(txt)
PY

# ---------------- completion bookkeeping ----------------
VERDICT=$(python3 -c "import json; print(json.load(open('$OUT_DIR/verdict_p.json'))['verdict'])")
if [ "$VERDICT" = "STRADDLE" ]; then
  say "STRADDLE declared — see $OUT_DIR/verdict_p.txt. No COMPLETE marker: the performance half stays open."
  say "Owner action required: sign the slice-assignment decision for runs 7–10 (proposal: run 6+k → pair k), then the stage-03 extension patch ships."
  exit 0
fi

if [ -z "${STAGE04_FORCE_VERIFY_ONLY:-}" ]; then
  date -u > "$OUT_DIR/COMPLETE"
  say "stage 04 COMPLETE — performance-half verdict: $VERDICT"
  echo "  verdict: $OUT_DIR/verdict_p.txt"
  echo "  verify:  bash stages/04-verdict.sh --verify"
  [ "$VERDICT" = "PASS" ] && echo "  next:    switch the STAGE file to 05-quality-gate" \
                          || echo "  next:    FAIL is a legitimate, publishable outcome (L7) — quality gate still runs for the record"
fi
