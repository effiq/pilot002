#!/usr/bin/env bash
# ============================================================
# Effiq Pilot 002 — STAGE 01: trace pipeline
# ------------------------------------------------------------
# Implements Protocol Lock v2.0 §L2 (frozen 2026-10-06,
# effiq/pilot002 commit 49277e2):
#   - download Azure LLM Inference Trace 2024 (conv + code, CC-BY)
#   - anchor raw files by sha256 (third-party artifact: anchored, not frozen)
#   - seeded slice selection: TRACE_SEED=20261010, 6 formal one-hour
#     slice pairs + 1 calibration slice pair, hour-aligned windows over
#     the intersection of both services' spans, disjoint by construction
#   - build per-pair replay plans (merged conv+code timeline, full slices:
#     thinning retention r and time compression C are applied at replay
#     time via the per-request keep_u value and the declared (r, C) —
#     plans themselves are load-shape-frozen)
#
# Determinism: given identical raw file hashes and TRACE_SEED, every
# output of this stage is byte-reproducible. Re-running after a pod wipe
# re-downloads and rebuilds everything identically.
#
# Modes:
#   (default)   run the pipeline (idempotent; resumes partial state)
#   --verify    offline recompute: checks anchors, re-derives slice
#               selection and plan hashes from the raw CSVs when present
#
# Disk layout:
#   ~/effiq/trace/                 raw CSVs + plans (bulk, pod-local,
#                                  NOT pushed — reproducible from source)
#   ~/effiq/pilot-logs/<date>/01-trace-pipeline/run_N/
#                                  anchors only: trace_hashes.json,
#                                  slices.json, plans_manifest.json,
#                                  summary.json, COMPLETE
#
# Test hooks (not used in production): EFFIQ_HOME, LOGS_DIR, TRACE_DIR,
# TRACE_CONV_URL, TRACE_CODE_URL env overrides.
# ============================================================
set -euo pipefail

# ---------------- locked constants (Protocol Lock v2.0) ----------------
TRACE_SEED=20261010          # frozen: slice selection seed
WINDOW_SECONDS=3600          # frozen: one-hour slices
N_FORMAL_PAIRS=6             # frozen: one slice pair per formal run
N_CALIBRATION_PAIRS=1        # frozen: separate calibration slice pair
CANDIDATE_DRAWS=20           # sampler draws; first 7 valid windows selected
MIN_REQUESTS_PER_SERVICE=100 # declared validity floor per window per service
MAX_SECONDS=3600             # soft time rail for this stage (CPU-only)
TRACE_SEED_NOTE="frozen by Protocol Lock v2.0 L2"

TRACE_CONV_URL_DEFAULT="https://github.com/Azure/AzurePublicDataset/releases/download/dataset-llm-2024/AzureLLMInferenceTrace_conv_1week.csv"
TRACE_CODE_URL_DEFAULT="https://github.com/Azure/AzurePublicDataset/releases/download/dataset-llm-2024/AzureLLMInferenceTrace_code_1week.csv"

# ---------------- paths (env-overridable for sandbox tests) ------------
EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
TRACE_DIR="${TRACE_DIR:-$EFFIQ_HOME/trace}"
PLANS_DIR="$TRACE_DIR/plans"
CONV_CSV="$TRACE_DIR/AzureLLMInferenceTrace_conv_1week.csv"
CODE_CSV="$TRACE_DIR/AzureLLMInferenceTrace_code_1week.csv"
TRACE_CONV_URL="${TRACE_CONV_URL:-$TRACE_CONV_URL_DEFAULT}"
TRACE_CODE_URL="${TRACE_CODE_URL:-$TRACE_CODE_URL_DEFAULT}"
STAGE_NAME="01-trace-pipeline"
DATE_STR="$(date -u +%Y-%m-%d)"
T0=$(date +%s)

say()  { printf '\n\033[1;36m[stage01] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[stage01][WARN] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[stage01][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

check_time_rail() {
  local elapsed=$(( $(date +%s) - T0 ))
  if [ "$elapsed" -gt "$MAX_SECONDS" ]; then
    die "time rail tripped (${elapsed}s > ${MAX_SECONDS}s). Partial state is resumable — re-run the nightly command."
  fi
}

# ---------------- run dir: resume-or-create (Pilot 001 pattern) --------
LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
if [ "${1:-}" != "--verify" ] && [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
  say "this stage is already COMPLETE — nothing to do."
  echo "  anchors: $LATEST"
  echo "  slices:  $LATEST/slices.json"
  echo "  next:    switch the STAGE file to 02-calibration"
  exit 0
fi

mkdir -p "$TRACE_DIR" "$PLANS_DIR"

# ============================================================
# --verify mode: offline recomputation of every anchor
# ============================================================
if [ "${1:-}" = "--verify" ]; then
  VD="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  [ -n "$VD" ] || die "--verify: no run directory found under $LOGS_DIR/*/$STAGE_NAME/"
  say "--verify against $VD"
  LOGS_DIR="$LOGS_DIR" TRACE_DIR="$TRACE_DIR" VD="$VD" \
  TRACE_SEED="$TRACE_SEED" WINDOW_SECONDS="$WINDOW_SECONDS" \
  N_FORMAL_PAIRS="$N_FORMAL_PAIRS" CANDIDATE_DRAWS="$CANDIDATE_DRAWS" \
  MIN_REQUESTS_PER_SERVICE="$MIN_REQUESTS_PER_SERVICE" \
  CONV_CSV="$CONV_CSV" CODE_CSV="$CODE_CSV" \
  python3 - <<'PY'
import csv, hashlib, json, os, random, sys
from datetime import datetime, timezone

VD        = os.environ["VD"]
TRACE_DIR = os.environ["TRACE_DIR"]
SEED      = int(os.environ["TRACE_SEED"])
WIN       = int(os.environ["WINDOW_SECONDS"])
N_FORMAL  = int(os.environ["N_FORMAL_PAIRS"])
DRAWS     = int(os.environ["CANDIDATE_DRAWS"])
MIN_REQ   = int(os.environ["MIN_REQUESTS_PER_SERVICE"])
CSVS      = {"conv": os.environ["CONV_CSV"], "code": os.environ["CODE_CSV"]}

checks = []
def check(name, ok, detail=""):
    checks.append((name, bool(ok), detail))

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def parse_ts(s):
    return datetime.fromisoformat(s).timestamp()

def scan(path):
    """rows, first_ts, last_ts, per-hour histogram"""
    rows, first, last = 0, None, None
    hist = {}
    with open(path, newline="") as f:
        r = csv.reader(f)
        hdr = next(r)
        assert hdr == ["TIMESTAMP", "ContextTokens", "GeneratedTokens"], f"unexpected header: {hdr}"
        for row in r:
            try:
                t = parse_ts(row[0]); int(row[1]); int(row[2])
            except Exception:
                continue  # same bad-row tolerance as the pipeline pass
            rows += 1
            first = t if first is None else min(first, t)
            last  = t if last  is None else max(last,  t)
            h = int(t // 3600)
            hist[h] = hist.get(h, 0) + 1
    return rows, first, last, hist

def select_windows(hists):
    """Deterministic slice selection — the single source of truth for the
    rule, shared by the pipeline and --verify. Returns ordered list of
    hour-indices: N_FORMAL formal pairs (chronological) + calibration."""
    first = max(min(h) for h in hists.values())       # intersection span,
    last  = min(max(h) for h in hists.values())       # in hour-index units
    candidates = list(range(first, last + 1))
    rng = random.Random(SEED)
    draws = rng.sample(candidates, min(DRAWS, len(candidates)))
    valid = [h for h in draws
             if all(hist.get(h, 0) >= MIN_REQ for hist in hists.values())]
    chosen = sorted(valid[:N_FORMAL + 1])
    return chosen

def plan_sha(window_hour, path, svc):
    """Recompute one service's contribution to a pair plan (hash only)."""
    lo, hi = window_hour * 3600.0, (window_hour + 1) * 3600.0
    h = hashlib.sha256()
    with open(path, newline="") as f:
        r = csv.reader(f)
        next(r)
        seq = 0
        for row in r:
            try:
                t = parse_ts(row[0]); int(row[1]); int(row[2])
            except Exception:
                continue  # same bad-row tolerance as the pipeline pass
            if lo <= t < hi:
                rid = f"{svc}-{window_hour}-{seq:06d}"
                seq += 1
                keep_u = int.from_bytes(
                    hashlib.sha256(f"{SEED}|{rid}".encode()).digest()[:8], "big") / 2**64
                rec = {"request_id": rid, "service": svc,
                       "arrival_offset_s": round(t - lo, 6),
                       "context_tokens": int(row[1]),
                       "generated_tokens": int(row[2]),
                       "keep_u": keep_u}
                h.update((json.dumps(rec, sort_keys=True) + "\n").encode())
    return h.hexdigest(), seq

# ---------- Level 1: internal consistency (no raw data needed) ----------
sj_path = os.path.join(VD, "slices.json")
th_path = os.path.join(VD, "trace_hashes.json")
pm_path = os.path.join(VD, "plans_manifest.json")
for p in (sj_path, th_path, pm_path):
    check(f"anchor exists: {os.path.basename(p)}", os.path.isfile(p), p)
if not all(ok for _, ok, _ in checks):
    for n, ok, d in checks:
        print(f"[{'PASS' if ok else 'FAIL'}] {n} {d}")
    sys.exit(1)

slices = json.load(open(sj_path))
th     = json.load(open(th_path))
pm     = json.load(open(pm_path))

check("trace_seed matches frozen value", slices["trace_seed"] == SEED, slices["trace_seed"])
check("window_seconds = 3600", slices["window_seconds"] == WIN)
sel = slices["selected"]
check("7 windows: 6 formal + 1 calibration",
      len(sel) == N_FORMAL + 1
      and sum(1 for s in sel if s["role"] == "formal") == N_FORMAL
      and sum(1 for s in sel if s["role"] == "calibration") == 1)
hours = [s["window_hour"] for s in sel]
check("windows distinct and hour-aligned",
      len(set(hours)) == len(hours) and all(isinstance(h, int) for h in hours))
check("windows chronological in file", hours == sorted(hours))
check("formal pairs occupy the first 6 slots chronologically",
      [s["role"] for s in sel] == ["formal"] * N_FORMAL + ["calibration"])

# ---------- Level 2: full recompute from raw CSVs (if present) ----------
if all(os.path.isfile(p) for p in CSVS.values()):
    hists, spans = {}, {}
    for svc, p in CSVS.items():
        digest = sha256_file(p)
        check(f"raw hash matches anchor [{svc}]",
              digest == th[svc]["sha256"], digest[:16] + "…")
        rows, first, last, hist = scan(p)
        check(f"row count matches anchor [{svc}]", rows == th[svc]["rows"], rows)
        check(f"span matches anchor [{svc}]",
              abs(first - th[svc]["first_ts"]) < 1e-6 and abs(last - th[svc]["last_ts"]) < 1e-6)
        hists[svc] = hist
    recomputed = select_windows(hists)
    check("slice selection reproduces exactly", recomputed == sorted(hours),
          f"{len(recomputed)} windows")
    for s in sel:
        for svc, p in CSVS.items():
            want = pm[s["pair_id"]][svc]["sha256"]
            got, n = plan_sha(s["window_hour"], p, svc)
            check(f"plan hash [{s['pair_id']}/{svc}]", got == want,
                  f"{n} rows")
else:
    print("[SKIP] raw CSVs not on disk — Level-2 recompute unavailable "
          "(re-run stage 01 to restore raw data; anchors above still verified)")

print()
all_ok = True
for n, ok, d in checks:
    all_ok &= ok
    print(f"[{'PASS' if ok else 'FAIL'}] {n}  {d}")
print()
print("VERIFY: ALL CHECKS PASSED" if all_ok else "VERIFY: FAILURES PRESENT")
sys.exit(0 if all_ok else 1)
PY
  exit $?
fi

# ============================================================
# default mode: run the pipeline
# ============================================================
if [ -n "$LATEST" ]; then
  RUN_DIR="$LATEST"
  say "resuming incomplete run dir: $RUN_DIR"
else
  BASE="$LOGS_DIR/$DATE_STR/$STAGE_NAME"
  mkdir -p "$BASE"
  N=1
  while [ -e "$BASE/run_$N" ]; do N=$((N+1)); done
  RUN_DIR="$BASE/run_$N"
  mkdir -p "$RUN_DIR"
fi
say "run dir: $RUN_DIR"

# ---------------- 1. download (resumable, hash-verified) ----------------
fetch_one() { # svc url path
  local svc="$1" url="$2" out="$3" want=""
  if [ -f "$RUN_DIR/trace_hashes.json" ]; then
    want="$(python3 -c "import json;print(json.load(open('$RUN_DIR/trace_hashes.json')).get('$svc',{}).get('sha256',''))" 2>/dev/null || true)"
  fi
  if [ -f "$out" ] && [ -n "$want" ]; then
    say "[$svc] raw file present — checking against anchored hash"
    [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$want" ] && { say "[$svc] hash matches anchor — skip download"; return 0; }
    warn "[$svc] hash mismatch against anchor — deleting and re-downloading"
    rm -f "$out"
  fi
  if [ ! -f "$out" ]; then
    say "[$svc] downloading $(basename "$out") (resumable)"
    curl -fL --retry 3 --retry-delay 5 -C - -o "$out" "$url" \
      || die "[$svc] download failed: $url"
  fi
}
fetch_one conv "$TRACE_CONV_URL" "$CONV_CSV"
check_time_rail
fetch_one code "$TRACE_CODE_URL" "$CODE_CSV"
check_time_rail

CONV_SHA="$(sha256sum "$CONV_CSV" | cut -d' ' -f1)"
CODE_SHA="$(sha256sum "$CODE_CSV" | cut -d' ' -f1)"
CONV_BYTES="$(stat -c%s "$CONV_CSV")"
CODE_BYTES="$(stat -c%s "$CODE_CSV")"
say "conv sha256: ${CONV_SHA:0:16}… (${CONV_BYTES} bytes)"
say "code sha256: ${CODE_SHA:0:16}… (${CODE_BYTES} bytes)"

# ---------------- 2. analyze → select → plans (one deterministic pass) --
# NOTE: the selection and plan-serialization rules below are byte-identical
# to those in --verify. Change both or neither; --verify exists to catch drift.
say "analyzing traces, selecting slices, building plans"
RUN_DIR="$RUN_DIR" TRACE_DIR="$TRACE_DIR" PLANS_DIR="$PLANS_DIR" \
TRACE_SEED="$TRACE_SEED" WINDOW_SECONDS="$WINDOW_SECONDS" \
N_FORMAL_PAIRS="$N_FORMAL_PAIRS" CANDIDATE_DRAWS="$CANDIDATE_DRAWS" \
MIN_REQUESTS_PER_SERVICE="$MIN_REQUESTS_PER_SERVICE" \
CONV_CSV="$CONV_CSV" CODE_CSV="$CODE_CSV" \
CONV_SHA="$CONV_SHA" CODE_SHA="$CODE_SHA" \
CONV_BYTES="$CONV_BYTES" CODE_BYTES="$CODE_BYTES" \
TRACE_SEED_NOTE="$TRACE_SEED_NOTE" \
python3 - <<'PY'
import csv, hashlib, json, os, random
from datetime import datetime, timezone

RUN_DIR   = os.environ["RUN_DIR"]
PLANS_DIR = os.environ["PLANS_DIR"]
SEED      = int(os.environ["TRACE_SEED"])
WIN       = int(os.environ["WINDOW_SECONDS"])
N_FORMAL  = int(os.environ["N_FORMAL_PAIRS"])
DRAWS     = int(os.environ["CANDIDATE_DRAWS"])
MIN_REQ   = int(os.environ["MIN_REQUESTS_PER_SERVICE"])
CSVS      = {"conv": os.environ["CONV_CSV"], "code": os.environ["CODE_CSV"]}
SHA       = {"conv": os.environ["CONV_SHA"], "code": os.environ["CODE_SHA"]}
BYTES     = {"conv": int(os.environ["CONV_BYTES"]), "code": int(os.environ["CODE_BYTES"])}

def parse_ts(s):
    return datetime.fromisoformat(s).timestamp()

def iso(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()

# ---- pass 1: schema check, row counts, span, per-hour histogram ----
stats, hists = {}, {}
for svc, path in CSVS.items():
    rows, first, last, bad = 0, None, None, 0
    hist = {}
    ctx_sum = gen_sum = 0
    with open(path, newline="") as f:
        r = csv.reader(f)
        hdr = next(r)
        assert hdr == ["TIMESTAMP", "ContextTokens", "GeneratedTokens"], \
            f"[{svc}] unexpected schema: {hdr}"
        for row in r:
            try:
                t = parse_ts(row[0]); c = int(row[1]); g = int(row[2])
            except Exception:
                bad += 1
                continue
            rows += 1
            first = t if first is None else min(first, t)
            last  = t if last  is None else max(last,  t)
            ctx_sum += c; gen_sum += g
            h = int(t // 3600)
            hist[h] = hist.get(h, 0) + 1
    stats[svc] = {"rows": rows, "first_ts": first, "last_ts": last,
                  "bad_rows": bad,
                  "context_tokens_total": ctx_sum, "generated_tokens_total": gen_sum}
    hists[svc] = hist
    print(f"[{svc}] rows={rows:,} span={iso(first)} → {iso(last)} bad_rows={bad}")

# ---- slice selection (rule identical to --verify) ----
first_h = max(min(h) for h in hists.values())
last_h  = min(max(h) for h in hists.values())
candidates = list(range(first_h, last_h + 1))
rng = random.Random(SEED)
draws = rng.sample(candidates, min(DRAWS, len(candidates)))
valid = [h for h in draws if all(hist.get(h, 0) >= MIN_REQ for hist in hists.values())]
if len(valid) < N_FORMAL + 1:
    raise SystemExit(f"only {len(valid)} valid windows among {len(draws)} draws — "
                     "insufficient dense hours; this is a Day-7-checkpoint-class finding, "
                     "stop and escalate to protocol review")
chosen = sorted(valid[:N_FORMAL + 1])
selected = []
for i, h in enumerate(chosen):
    role = "formal" if i < N_FORMAL else "calibration"
    pair_id = f"pair_{i+1}" if role == "formal" else "calibration"
    selected.append({
        "pair_id": pair_id, "role": role, "window_hour": h,
        "window_start_iso": iso(h * 3600),
        "conv_rows": hists["conv"].get(h, 0), "code_rows": hists["code"].get(h, 0),
    })

# ---- pass 2: build merged per-pair replay plans (full slices; thinning
# retention r and compression C are applied downstream at replay time) ----
def plan_lines(window_hour, path, svc):
    lo, hi = window_hour * 3600.0, (window_hour + 1) * 3600.0
    out = []
    with open(path, newline="") as f:
        r = csv.reader(f)
        next(r)
        seq = 0
        for row in r:
            try:
                t = parse_ts(row[0]); int(row[1]); int(row[2])
            except Exception:
                continue
            if lo <= t < hi:
                rid = f"{svc}-{window_hour}-{seq:06d}"
                seq += 1
                keep_u = int.from_bytes(
                    hashlib.sha256(f"{SEED}|{rid}".encode()).digest()[:8], "big") / 2**64
                rec = {"request_id": rid, "service": svc,
                       "arrival_offset_s": round(t - lo, 6),
                       "context_tokens": int(row[1]),
                       "generated_tokens": int(row[2]),
                       "keep_u": keep_u}
                out.append(json.dumps(rec, sort_keys=True) + "\n")
    return out

manifest = {}
for s in selected:
    per_svc, merged = {}, []
    for svc, path in CSVS.items():
        lines = plan_lines(s["window_hour"], path, svc)
        h = hashlib.sha256()
        for ln in lines:
            h.update(ln.encode())
        per_svc[svc] = {"sha256": h.hexdigest(), "rows": len(lines)}
        merged.extend(lines)
    merged.sort(key=lambda ln: (json.loads(ln)["arrival_offset_s"],
                                json.loads(ln)["service"],
                                json.loads(ln)["request_id"]))
    mh = hashlib.sha256()
    for ln in merged:
        mh.update(ln.encode())
    plan_file = os.path.join(PLANS_DIR, f"{s['pair_id']}.jsonl")
    with open(plan_file, "w") as f:
        f.writelines(merged)
    manifest[s["pair_id"]] = {
        "window_hour": s["window_hour"], **per_svc,
        "merged_sha256": mh.hexdigest(), "merged_rows": len(merged),
        "plan_file": plan_file,
        "note": "full slice; apply thinning (keep_u < r) and compression "
                "(arrival_offset_s / C) at replay time per Protocol Lock v2.0 L2",
    }
    print(f"[{s['pair_id']}] window={s['window_start_iso']} "
          f"conv={per_svc['conv']['rows']:,} code={per_svc['code']['rows']:,} "
          f"merged_sha={mh.hexdigest()[:16]}…")

# ---- anchors into the log run dir ----
trace_hashes = {
    svc: {"file": os.path.basename(CSVS[svc]), "sha256": SHA[svc], "bytes": BYTES[svc],
          "rows": stats[svc]["rows"], "bad_rows": stats[svc]["bad_rows"],
          "first_ts": stats[svc]["first_ts"], "last_ts": stats[svc]["last_ts"],
          "first_iso": iso(stats[svc]["first_ts"]), "last_iso": iso(stats[svc]["last_ts"]),
          "context_tokens_total": stats[svc]["context_tokens_total"],
          "generated_tokens_total": stats[svc]["generated_tokens_total"],
          "source_url": os.environ.get("TRACE_CONV_URL" if svc == "conv" else "TRACE_CODE_URL",
                                       "default")}
    for svc in CSVS
}
trace_hashes["_note"] = ("third-party artifact (Azure LLM Inference Trace 2024, CC-BY, "
                         "DynamoLLM HPCA'25): hash-anchored, not frozen by us")
json.dump(trace_hashes, open(os.path.join(RUN_DIR, "trace_hashes.json"), "w"), indent=2)

slices_doc = {
    "trace_seed": SEED, "seed_note": os.environ["TRACE_SEED_NOTE"],
    "window_seconds": WIN,
    "rule": (f"hour-aligned windows over the intersection of both services' spans; "
             f"Random({SEED}).sample(candidates, {DRAWS}); first {N_FORMAL + 1} windows with "
             f">= {MIN_REQ} requests in BOTH services selected; chronological order; "
             f"first {N_FORMAL} = formal pairs, last = calibration pair (watermarked: "
             "CALIBRATION DATA ONLY — never enters the CI)"),
    "candidates_in_intersection": len(candidates),
    "draws": [iso(h * 3600) for h in draws],
    "selected": selected,
}
json.dump(slices_doc, open(os.path.join(RUN_DIR, "slices.json"), "w"), indent=2)
json.dump(manifest, open(os.path.join(RUN_DIR, "plans_manifest.json"), "w"), indent=2)

summary = {
    "stage": "01-trace-pipeline", "status": "COMPLETE",
    "trace_seed": SEED,
    "conv_sha256": SHA["conv"], "code_sha256": SHA["code"],
    "formal_pairs": [s["pair_id"] for s in selected if s["role"] == "formal"],
    "calibration_pair": "calibration",
    "plans_dir": PLANS_DIR,
}
json.dump(summary, open(os.path.join(RUN_DIR, "summary.json"), "w"), indent=2)
open(os.path.join(RUN_DIR, "COMPLETE"), "w").write("ok\n")

print()
print("=== stage 01 summary ===")
print(f"formal pairs 1..{N_FORMAL} + calibration pair selected (seed {SEED})")
for s in selected:
    print(f"  {s['pair_id']:<12} {s['window_start_iso']}  "
          f"conv={s['conv_rows']:,}  code={s['code_rows']:,}")
print("anchors written to run dir; plans (bulk) under plans dir — reproducible, not pushed")
PY
check_time_rail

say "✅ stage 01 COMPLETE"
echo "  anchors: $RUN_DIR"
echo "  plans:   $PLANS_DIR (pod-local bulk; hash-anchored, reproducible)"
echo "  verify:  bash stages/01-trace-pipeline.sh --verify"
echo "  next:    switch the STAGE file to 02-calibration (not yet shipped)"
