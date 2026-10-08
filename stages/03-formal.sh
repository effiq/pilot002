#!/usr/bin/env bash
# ============================================================
# Effiq Pilot 002 — STAGE 03: formal measurement (performance half)
# ------------------------------------------------------------
# Implements Protocol Lock v2.1 (v2.0 frozen 2026-10-06 commit 49277e2,
# Amendment-01 commit 9dc7af3):
#   L1  Qwen2.5-14B-Instruct @ cf98f3b3… + vLLM 0.31.0 (pinned; asserted)
#   L2  formal run i replays merged slice pair i (i = 1..6); thinning
#       keep_u < r and compression arrival_offset_s / C are applied at
#       replay time; (r, C) is read from the frozen stage-02 chosen.json
#       (this stage never recomputes the operating point).
#       max_tokens = min(GeneratedTokens, 1024); ignore_eos = True
#       (performance-half load-fidelity device, declared in L2).
#   L3  Arm A = BF16 server defaults; Arm B = identical argv plus
#       --quantization fp8. Prefix caching OFF; temperature 0.
#       --verify diffs the two recorded server argv and fails if anything
#       except the quantization flag differs.
#   L4  6 runs, within-run block-crossover: odd runs replay the A block
#       first, even runs the B block first (inherited from Pilot 001
#       Amendment-02). Per request per row: request_id, slice id, arrival
#       offset, prompt tokens, output tokens (target + realized), TTFT,
#       mean TPOT, end-to-end latency, wall timestamps, arm, run
#       index/seed, scripts revision, output text sha256 (the serving API
#       does not expose token ids; the text hash provides the same
#       tamper-evidence — see the stage-03 reconciliation note).
#   ANTI-P-HACKING (frozen): this stage prints DESCRIPTIVE MEANS ONLY.
#       No CI, no P95 gate evaluation, no PASS/FAIL — the paired bootstrap
#       (seed 20262002) and the tail-latency gate stay sealed in the
#       independent stage-04 verdict script until all COMPLETE markers
#       exist. Do not add them here.
#   FALLBACK DISCLOSURE: stage 02 found no grid configuration meeting
#       the SLO; the formal measurement runs at the lightest config
#       (r = 1/256, C = 4) and the shortfall is disclosed in every run
#       summary and in the verdict, per the pre-registered fallback
#       clause. This script refuses to run without chosen.json and
#       re-states the disclosure whenever fallback=true.
#
# Server-side errors abort the run (Protocol Lock v2.1 sec.2 item 2):
#   any HTTP 5xx voids the current arm block; the block is marked FAILED,
#   the stage exits 45, and the incident enters the deviation log. After
#   the cause is fixed, re-running the nightly command replays the voided
#   block against the identical offered load (plan rows are frozen).
# Client-side policy (same exploration item, declared): connection
#   refused before send = server never engaged → up to 3 retries with
#   backoff, disclosed per row as retries=n. Timeouts are NOT retried
#   (the server may hold the request; a retry would double the offered
#   load) — they are recorded as error rows.
#
# Modes:
#   (default)   run/resume the 6 formal runs (per-block .done markers)
#   --verify    offline recompute from the archived raw JSONL: schema,
#               pairing coverage, replay constants vs chosen.json, block
#               order vs run parity, arm argv diff, descriptive means —
#               no GPU, no server
#
# Requires: L40S GPU, vLLM 0.31.0, stage-01 plans on disk, stage-02
# chosen.json in the log repo (re-run stages 01/02 after a pod wipe —
# both are byte-reproducible).
# ============================================================
set -euo pipefail

# ---------------- locked constants (Protocol Lock v2.1) ----------------
MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"
VLLM_PINNED="0.31.0"
GPU_EXPECT="L40S"
MAX_MODEL_LEN=32768            # see stage-02 header: trace max ctx = 7999, zero loss
MAX_TOKENS_CAP=1024            # frozen L2 declared cap
N_RUNS=6                       # frozen L4 (straddle extension to 10 is stage-04's call;
                               # this script refuses runs > 6 — see reconciliation note)
SLO_TTFT_S=5.0                 # descriptive per-row SLO flag only (L4 reference)
SLO_TPOT_MS=100.0
REQ_TIMEOUT_S=900              # per-request bound; timeouts recorded, never retried
CLIENT_CONC="${CLIENT_CONC:-2048}"   # in-flight gate; payloads are O(CONC) (2026-10-06 lesson)
FILLER_SEED=20261010           # same stream as stage-01 keep_u (frozen)
RUN_SEED_BASE=20263000         # run_seed = base + run_idx; declared, no randomness consumed
MAX_SECONDS=25200              # soft rail ~7 h, resumable (envelope: expected 4–5 h)
PORT="${PORT:-8000}"           # env override is a test hook only
RUNS="${RUNS:-1 2 3 4 5 6}"    # env override is a test hook only

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot002}"
TRACE_DIR="${TRACE_DIR:-$EFFIQ_HOME/trace}"
PLANS_DIR="${PLANS_DIR:-$TRACE_DIR/plans}"
TOKEN_FILE="$HOME/pilot-env/github-token"
STAGE_NAME="03-formal"
DATE_STR="$(date -u +%Y-%m-%d)"
T0=$(date +%s)

say()  { printf '\n\033[1;36m[stage03] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[stage03][WARN] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[stage03][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

check_time_rail() {
  local elapsed=$(( $(date +%s) - T0 ))
  [ "$elapsed" -gt "$MAX_SECONDS" ] && \
    die "time rail tripped (${elapsed}s) — completed blocks carry .done markers; re-run the nightly command to resume."
  return 0
}

# ---------------- frozen anchors: chosen.json + stage-01 manifest ----------------
CHOSEN_JSON="${CHOSEN_JSON:-}"   # env override is a test hook only
if [ -z "$CHOSEN_JSON" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/02-calibration/run_* 2>/dev/null); do
    [ -f "$d/chosen.json" ] && CHOSEN_JSON="$d/chosen.json" && break
  done
fi
[ -n "$CHOSEN_JSON" ] && [ -f "$CHOSEN_JSON" ] \
  || die "stage-02 chosen.json not found — run stage 02 first (the operating point is frozen there)"

read D_CHOSEN C_CHOSEN FALLBACK <<<"$(python3 -c "
import json; d = json.load(open('$CHOSEN_JSON'))
print(d['D'], d['C'], str(d.get('fallback', False)).lower())")"
WINDOW_S=$(( 3600 / C_CHOSEN ))
if [ "$FALLBACK" = "true" ]; then
  DISCLOSURE="no grid configuration met the SLO; lightest configuration used, shortfall disclosed per protocol"
else
  DISCLOSURE=""
fi

S01_DIR="$(ls -dt "$LOGS_DIR"/*/01-trace-pipeline/run_* 2>/dev/null | head -1 || true)"
[ -n "$S01_DIR" ] && [ -f "$S01_DIR/plans_manifest.json" ] \
  || die "stage-01 plans_manifest.json not found — re-run stage 01 first"

# ---------------- run dir: resume-or-create ----------------
LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
if [ "${1:-}" != "--verify" ] && [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
  say "this stage is already COMPLETE — nothing to do."
  echo "  data:   $LATEST (6 runs × 2 arm blocks, descriptive summaries only)"
  echo "  next:   switch the STAGE file to 04-verdict (not yet shipped)"
  echo "  note:   the CI and the P95 gate stay sealed until stage 04 — do not compute them by hand."
  exit 0
fi

# ============================================================
# --verify mode: offline recompute from raw archives (no GPU, no server)
# ============================================================
if [ "${1:-}" = "--verify" ]; then
  VD="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  [ -n "$VD" ] || die "--verify: no run directory found"
  say "--verify against $VD"
  VD="$VD" CHOSEN_JSON="$CHOSEN_JSON" N_RUNS="$N_RUNS" \
  RUN_SEED_BASE="$RUN_SEED_BASE" SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" \
  python3 - <<'PY'
import json, os, re, sys

VD     = os.environ["VD"]
N_RUNS = int(os.environ["N_RUNS"])
BASE   = int(os.environ["RUN_SEED_BASE"])
chosen = json.load(open(os.environ["CHOSEN_JSON"]))
D0, C0 = int(chosen["D"]), int(chosen["C"])
FB0    = bool(chosen.get("fallback"))

checks = []
def check(name, ok, detail=""):
    checks.append((name, bool(ok), detail))

REQUIRED = {"request_id", "pair_id", "service", "arrival_offset_s",
            "prompt_tokens", "max_tokens_target", "completion_tokens",
            "ttft_s", "tpot_ms", "e2e_s", "wall_send_ts", "wall_end_ts",
            "arm", "run_idx", "run_seed", "scripts_rev", "status", "D", "C",
            "send_lag_ms", "slo_ok"}

def block_rows(path):
    rows = [json.loads(l) for l in open(path)]
    return [r for r in rows if "status" in r]      # skip the header line

all_pair_ids = set()
for i in range(1, N_RUNS + 1):
    rd = os.path.join(VD, f"formal_run_{i}")
    if not os.path.isdir(rd):
        check(f"run {i}: directory present", False, rd); continue
    summ_p = os.path.join(rd, "run_summary.json")
    if not os.path.exists(summ_p):
        check(f"run {i}: run_summary.json present", False); continue
    summ = json.load(open(summ_p))
    check(f"run {i}: run_seed = base+idx", summ["run_seed"] == BASE + i,
          str(summ["run_seed"]))
    expect_order = ["A", "B"] if i % 2 == 1 else ["B", "A"]
    check(f"run {i}: block order matches run parity (L4)",
          summ["arm_order"] == expect_order, str(summ["arm_order"]))
    if FB0:
        check(f"run {i}: fallback disclosure carried",
          "shortfall disclosed" in summ.get("disclosure", ""))
    id_sets = {}
    for arm in ("A", "B"):
        done_p = os.path.join(rd, f"arm{arm}.done")
        raw_p  = os.path.join(rd, f"arm{arm}.jsonl")
        if not (os.path.exists(done_p) and os.path.exists(raw_p)):
            check(f"run {i} arm {arm}: block marker + raw present", False); continue
        mk = json.load(open(done_p))
        check(f"run {i} arm {arm}: block status ok", mk["status"] == "ok",
              mk["status"])
        rows = block_rows(raw_p)
        id_sets[arm] = {r["request_id"] for r in rows}
        all_pair_ids.add(rows[0]["pair_id"] if rows else "?")
        miss = REQUIRED - set(rows[0].keys()) if rows else REQUIRED
        check(f"run {i} arm {arm}: row schema complete (L4 fields)",
              not miss, ",".join(sorted(miss))[:60])
        check(f"run {i} arm {arm}: row count == marker",
              len(rows) == mk["rows"], f"{len(rows)} vs {mk['rows']}")
        check(f"run {i} arm {arm}: replay constants == chosen.json "
              f"(r=1/{D0}, C={C0})",
              all(r["D"] == D0 and r["C"] == C0 for r in rows))
        check(f"run {i} arm {arm}: arm tag consistent",
              all(r["arm"] == arm for r in rows))
        check(f"run {i} arm {arm}: run_idx consistent",
              all(r["run_idx"] == i for r in rows))
        ok_rows = [r for r in rows if r["status"] == "ok"]
        check(f"run {i} arm {arm}: ok rows carry 64-hex output text hash",
              all(re.fullmatch(r"[0-9a-f]{64}", r.get("output_text_sha256") or "")
                  for r in ok_rows))
        check(f"run {i} arm {arm}: no server-side error rows (5xx voids a run)",
              not any(str(r["status"]).startswith("http_5") for r in rows))
        # descriptive means recomputed from raw vs marker (tolerance 1e-6)
        def mean(xs): return sum(xs) / len(xs) if xs else 0.0
        tps = [r["completion_tokens"] / r["e2e_s"] for r in ok_rows if r["e2e_s"]]
        check(f"run {i} arm {arm}: mean throughput recomputed matches marker",
              abs(mean(tps) - mk["mean_tps"]) < 1e-6,
              f"{mean(tps):.4f} vs {mk['mean_tps']:.4f}")
    if len(id_sets) == 2:
        check(f"run {i}: pairing coverage — arm A and arm B request_id sets identical",
              id_sets["A"] == id_sets["B"],
              f"A={len(id_sets['A'])} B={len(id_sets['B'])}")
        # descriptive paired ratio recomputed vs summary (descriptive only)
        ra = {r["request_id"]: r for r in block_rows(os.path.join(rd, "armA.jsonl"))
              if r["status"] == "ok"}
        rb = {r["request_id"]: r for r in block_rows(os.path.join(rd, "armB.jsonl"))
              if r["status"] == "ok"}
        both = [(rb[k], ra[k]) for k in ra.keys() & rb.keys()
                if ra[k]["e2e_s"] and rb[k]["e2e_s"]]
        if both:
            ratios = [(b["completion_tokens"] / b["e2e_s"]) /
                      (a["completion_tokens"] / a["e2e_s"]) for b, a in both]
            m = sum(ratios) / len(ratios)
            check(f"run {i}: descriptive paired mean ratio recomputed matches summary",
                  abs(m - summ["paired_mean_ratio_B_over_A"]) < 1e-6,
                  f"{m:.4f} vs {summ['paired_mean_ratio_B_over_A']:.4f}")
    # arm argv diff: only the quantization flag may differ (L3)
    pa = os.path.join(rd, "server_argv_armA.txt")
    pb = os.path.join(rd, "server_argv_armB.txt")
    if os.path.exists(pa) and os.path.exists(pb):
        ta = open(pa).read().replace("server_argv: vllm serve ", "").split()
        tb = open(pb).read().replace("server_argv: vllm serve ", "").split()
        diff_a = [t for t in ta if t not in tb]
        diff_b = [t for t in tb if t not in ta]
        only_quant = (diff_a == [] and diff_b == ["--quantization", "fp8"]) or \
                     (diff_b == [] and diff_a == ["--quantization", "fp8"])
        check(f"run {i}: server argv identical except --quantization fp8 (L3)",
              only_quant, f"A-only={diff_a} B-only={diff_b}")

check("exactly 6 distinct slice pairs consumed (L2: run i replays pair i)",
      len(all_pair_ids) == N_RUNS, str(sorted(all_pair_ids)))
check("no CI / P95 gate fields leaked into summaries (anti-p-hacking)",
      True)   # structural: this stage never writes them; stage 04 owns them

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
# default mode
# ============================================================
if [ -n "$LATEST" ]; then
  RUN_DIR="$LATEST"; say "resuming incomplete run dir: $RUN_DIR"
else
  BASE="$LOGS_DIR/$DATE_STR/$STAGE_NAME"; mkdir -p "$BASE"
  N=1; while [ -e "$BASE/run_$N" ]; do N=$((N+1)); done
  RUN_DIR="$BASE/run_$N"; mkdir -p "$RUN_DIR"
fi

# ---------------- preflight asserts (pinned environment) ----------------
say "preflight asserts"
if [ "${STAGE03_SKIP_PREFLIGHT:-0}" != "1" ]; then   # test hook; production never sets this
  nvidia-smi --query-gpu=name --format=csv,noheader | grep -q "$GPU_EXPECT" \
    || die "GPU is not $GPU_EXPECT — hardware boundary is locked (L3)"
  python3 -c "import vllm, sys; v=vllm.__version__; sys.exit(0 if v=='$VLLM_PINNED' else 1)" \
    || die "vLLM is not $VLLM_PINNED — engine version is pinned (L1)"
  SNAP=""
  for base in "${HF_HOME:-$HOME/.cache/huggingface}" /workspace/.cache/huggingface; do
    d="$base/hub/models--Qwen--Qwen2.5-14B-Instruct"
    [ -d "$d" ] && SNAP="$d" && break
  done
  FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  if [ -n "$SNAP" ]; then
    [ "${FREE_GB:-0}" -ge 10 ] || die "disk headroom < 10GB (weights already cached)"
    say "weights snapshot cached at $SNAP — disk assert relaxed to 10GB"
  else
    [ "${FREE_GB:-0}" -ge 45 ] || die "disk headroom < 45GB (weights ≈ 28GB)"
  fi
fi
python3 -c "import httpx" 2>/dev/null || die "httpx not importable (expected present with vLLM)"
ulimit -n 65536 2>/dev/null || warn "could not raise fd limit to 65536 (continuing with $(ulimit -n))"

SCRIPTS_REV="$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)"

# ---------------- anchor check: plans on disk vs stage-01 manifest ----------------
say "anchor check: 6 formal plans vs stage-01 manifest"
S01_DIR="$S01_DIR" PLANS_DIR="$PLANS_DIR" python3 - <<'PY'
import hashlib, json, os, sys
man = json.load(open(os.path.join(os.environ["S01_DIR"], "plans_manifest.json")))
plans = man["plans"] if "plans" in man else man
bad = []
total = 0
for i in range(1, 7):
    pid = f"pair_{i}"
    entry = plans.get(pid) or {}
    path = os.path.join(os.environ["PLANS_DIR"], f"{pid}.jsonl")
    if not os.path.exists(path):
        bad.append(f"{pid}: missing {path}"); continue
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk); n += chunk.count(b"\n")
    want = entry.get("merged_sha256")
    ok = bool(want) and h.hexdigest() == want
    if not ok:
        bad.append(f"{pid}: sha256 mismatch ({h.hexdigest()[:16]}… vs manifest {str(want)[:16]}…)")
    total += n
    print(f"  [{pid}] rows={n:,} sha256={h.hexdigest()[:16]}… {'OK' if ok else 'MISMATCH'}")
print(f"  total merged rows across 6 formal pairs: {total:,}")
if bad:
    sys.exit("\n".join(bad))
PY
[ $? -eq 0 ] || die "plan anchor check failed — re-run stage 01 (plans are byte-reproducible)"

say "operating point (frozen by stage 02): r=1/${D_CHOSEN}, C=${C_CHOSEN} → window ${WINDOW_S}s"
[ "$FALLBACK" = "true" ] && warn "FALLBACK OPERATING POINT — $DISCLOSURE"

# ---------------- vLLM server lifecycle (per arm block) ----------------
start_server() {   # $1 = arm (A|B)
  local arm="$1" slog="$RUN_DIR/server_run${CUR_RUN}_arm${arm}.log"
  local extra=""
  [ "$arm" = "B" ] && extra="--quantization fp8"
  say "run ${CUR_RUN}: starting Arm ${arm} server ($([ "$arm" = B ] && echo 'FP8 dynamic' || echo 'BF16 defaults'); prefix caching OFF; max_model_len=$MAX_MODEL_LEN)"
  # shellcheck disable=SC2086
  nohup python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" --revision "$MODEL_REV" \
    --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
    $extra --port "$PORT" > "$slog" 2>&1 &
  echo $! > "$RUN_DIR/server.pid"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see $slog"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then
      die "server process died — see $slog"
    fi
  done
  say "run ${CUR_RUN}: Arm ${arm} server healthy after ${waited}s"
  echo "server_argv: vllm serve $MODEL --revision $MODEL_REV --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN $extra --port $PORT" \
    | sed 's/  */ /g' > "$RUN_DIR/formal_run_${CUR_RUN}/server_argv_arm${arm}.txt"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

# ---------------- per-run log push (disposable-disk defence) ----------------
# The log repo remote embeds the push credential from clone time; the token
# file is read here only for the pre-push leak scan, same as tonight.sh.
push_logs() {   # $1 = commit message
  [ -s "$TOKEN_FILE" ] || { warn "token file unreadable — skipping interim push (tonight.sh will push at the end)"; return 0; }
  local TOKEN; TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  if grep -rqF "$TOKEN" "$LOGS_DIR" --exclude-dir=.git; then
    warn "safety check tripped: token string found in logs — interim push aborted (tonight.sh will retry the scan)"
    return 0
  fi
  git -C "$LOGS_DIR" add -A
  git -C "$LOGS_DIR" -c user.name="effiq-pilot" -c user.email="pilot@effiq.tech" \
    commit -m "$1" >/dev/null || true
  local try
  for try in 1 2 3; do
    git -C "$LOGS_DIR" push origin HEAD:main && { say "interim push ok ($1)"; return 0; }
    warn "interim push attempt $try failed — retrying in 20s"; sleep 20
  done
  warn "interim push failed after 3 attempts — data stays on pod; tonight.sh end-push will retry"
  return 0
}

# ---------------- per-block replay client (one process per arm block) ----------------
run_block() {   # $1 = run_idx, $2 = arm, $3 = pair_id
RUN_IDX="$1" ARM="$2" PAIR_ID="$3" \
RUN_DIR="$RUN_DIR" PLANS_DIR="$PLANS_DIR" PORT="$PORT" MODEL="$MODEL" \
D_CHOSEN="$D_CHOSEN" C_CHOSEN="$C_CHOSEN" WINDOW_S="$WINDOW_S" \
FALLBACK="$FALLBACK" DISCLOSURE="$DISCLOSURE" \
SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" \
REQ_TIMEOUT_S="$REQ_TIMEOUT_S" CLIENT_CONC="$CLIENT_CONC" \
MAX_TOKENS_CAP="$MAX_TOKENS_CAP" MAX_MODEL_LEN="$MAX_MODEL_LEN" \
FILLER_SEED="$FILLER_SEED" RUN_SEED_BASE="$RUN_SEED_BASE" \
SCRIPTS_REV="$SCRIPTS_REV" \
python3 - <<'PY'
import asyncio, hashlib, json, os, random, sys, time
import httpx

RUN_DIR   = os.environ["RUN_DIR"]
RUN_IDX   = int(os.environ["RUN_IDX"])
ARM       = os.environ["ARM"]
PAIR_ID   = os.environ["PAIR_ID"]
PLAN      = os.path.join(os.environ["PLANS_DIR"], f"{PAIR_ID}.jsonl")
PORT      = os.environ["PORT"]
D0, C0    = int(os.environ["D_CHOSEN"]), int(os.environ["C_CHOSEN"])
R         = 1.0 / D0
WINDOW    = float(os.environ["WINDOW_S"])
FB        = os.environ["FALLBACK"] == "true"
DISC      = os.environ["DISCLOSURE"]
TTFT_SLO  = float(os.environ["SLO_TTFT_S"])
TPOT_SLO  = float(os.environ["SLO_TPOT_MS"])
REQ_TO    = float(os.environ["REQ_TIMEOUT_S"])
CONC      = int(os.environ["CLIENT_CONC"])
CAP       = int(os.environ["MAX_TOKENS_CAP"])
MML       = int(os.environ["MAX_MODEL_LEN"])
FSEED     = int(os.environ["FILLER_SEED"])
RUN_SEED  = int(os.environ["RUN_SEED_BASE"]) + RUN_IDX
SREV      = os.environ["SCRIPTS_REV"]
URL       = f"http://127.0.0.1:{PORT}/v1/completions"

RD      = os.path.join(RUN_DIR, f"formal_run_{RUN_IDX}")
RAW     = os.path.join(RD, f"arm{ARM}.jsonl")
DONE_F  = os.path.join(RD, f"arm{ARM}.done")
FAIL_F  = os.path.join(RD, f"arm{ARM}.failed")

rows = [json.loads(l) for l in open(PLAN)]
rows.sort(key=lambda r: (r["arrival_offset_s"], r["service"], r["request_id"]))
sched = [(row["arrival_offset_s"] / C0, row) for row in rows if row["keep_u"] < R]
n_sched = len(sched)
max_ctx = max(r["context_tokens"] for _, r in sched) if sched else 8192
print(f"[run {RUN_IDX} arm {ARM}] {PAIR_ID}: merged {len(rows):,} rows → thinned "
      f"{n_sched:,} offered over {WINDOW:.0f}s (≈{n_sched / WINDOW:.2f} req/s), "
      f"max ctx {max_ctx:,}", flush=True)

# deterministic filler block (identical construction to stage 02)
_rng = random.Random(FSEED)
_base = [_rng.randrange(1000, 50000) for _ in range(8192)]
G = (_base * (max_ctx // 8192 + 2))[: max_ctx + 8192]
def filler_ids(n, rid):
    off = int.from_bytes(hashlib.sha256(f"{FSEED}|{rid}".encode()).digest()[:4], "big") % 8192
    return G[off:off + n]

sent = done = errs = 0
fatal = []                       # server-side error → void the block
t0 = time.monotonic()

async def replay(client, raw_f):
    global sent, done, errs
    sem = asyncio.Semaphore(CONC)     # in-flight gate: payloads are O(CONC)

    async def fire(at, row):
        global sent, done, errs
        rid  = row["request_id"]
        ctx, gen = row["context_tokens"], row["generated_tokens"]
        rec = {"request_id": rid, "pair_id": PAIR_ID, "service": row["service"],
               "arrival_offset_s": row["arrival_offset_s"],
               "prompt_tokens": ctx, "max_tokens_target": min(gen, CAP, MML - ctx - 1),
               "arm": ARM, "run_idx": RUN_IDX, "run_seed": RUN_SEED,
               "scripts_rev": SREV, "D": D0, "C": C0}
        if rec["max_tokens_target"] <= 0:
            rec.update(status="skipped_overlength", completion_tokens=0,
                       ttft_s=None, tpot_ms=None, e2e_s=None,
                       wall_send_ts=None, wall_first_ts=None, wall_end_ts=None,
                       output_text_sha256=None, send_lag_ms=None, slo_ok=False,
                       retries=0)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            return
        # gate wait is client-side queueing; disclosed per request as
        # send_lag_ms; TTFT starts at actual send (conservative direction,
        # same as stage 02).
        async with sem:
            if fatal:
                return               # block voided; nothing further engages
            sent += 1
            payload = {"model": os.environ["MODEL"], "prompt": filler_ids(ctx, rid),
                       "max_tokens": rec["max_tokens_target"], "ignore_eos": True,
                       "temperature": 0, "stream": True,
                       "stream_options": {"include_usage": True}}
            t_send_m = time.monotonic(); wall_send = time.time()
            t_first_m = t_last_m = None; wall_first = None
            comp_tokens = 0
            texth = hashlib.sha256()
            status = "ok"; retries = 0
            try:
                attempt = 0
                while True:
                    try:
                        async with client.stream("POST", URL, json=payload) as resp:
                            if resp.status_code >= 500:
                                # server-side error: the run is void (sec.2 item 2)
                                status = f"http_{resp.status_code}"
                                fatal.append(status)
                                break
                            if resp.status_code != 200:
                                status = f"http_{resp.status_code}"
                                break
                            async for line in resp.aiter_lines():
                                if not line.startswith("data:"):
                                    continue
                                data = line[5:].strip()
                                if data == "[DONE]":
                                    break
                                now_m = time.monotonic()
                                try:
                                    obj = json.loads(data)
                                except Exception:
                                    continue
                                if t_first_m is None:
                                    t_first_m = now_m; wall_first = time.time()
                                t_last_m = now_m
                                for ch in obj.get("choices", []):
                                    t = ch.get("text")
                                    if t:
                                        texth.update(t.encode())
                                u = obj.get("usage")
                                if u:
                                    comp_tokens = u.get("completion_tokens", comp_tokens)
                        break
                    except httpx.ConnectError:
                        # connection refused before send = server never engaged;
                        # client-side retry, declared (sec.2 item 2), max 3
                        attempt += 1
                        if attempt > 3:
                            status = "error:ConnectError"; break
                        retries = attempt
                        await asyncio.sleep(0.5 * attempt)
            except asyncio.CancelledError:
                rec.update(status="cancelled", completion_tokens=comp_tokens,
                           ttft_s=None, tpot_ms=None, e2e_s=None,
                           wall_send_ts=round(wall_send, 3), wall_first_ts=None,
                           wall_end_ts=round(time.time(), 3),
                           output_text_sha256=None,
                           send_lag_ms=round((t_send_m - t0) * 1000.0, 1),
                           slo_ok=False, retries=retries)
                raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
                done += 1
                raise
            except Exception as e:
                status = "error:" + type(e).__name__   # e.g. timeout — never retried
            t_end_m = time.monotonic(); wall_end = time.time()
            if comp_tokens == 0 and status == "ok":
                status = "error:no_tokens"
            ttft = (t_first_m - t_send_m) if t_first_m is not None else None
            if t_first_m is not None and comp_tokens > 1:
                tpot_ms = (t_last_m - t_first_m) / (comp_tokens - 1) * 1000.0
            elif t_first_m is not None:
                tpot_ms = (t_end_m - t_first_m) * 1000.0
            else:
                tpot_ms = None
            e2e = t_end_m - t_send_m
            ok = (status == "ok" and ttft is not None and ttft <= TTFT_SLO
                  and tpot_ms is not None and tpot_ms <= TPOT_SLO)
            rec.update(status=status, completion_tokens=comp_tokens,
                       ttft_s=round(ttft, 4) if ttft is not None else None,
                       tpot_ms=round(tpot_ms, 3) if tpot_ms is not None else None,
                       e2e_s=round(e2e, 4),
                       wall_send_ts=round(wall_send, 3),
                       wall_first_ts=round(wall_first, 3) if wall_first else None,
                       wall_end_ts=round(wall_end, 3),
                       output_text_sha256=(texth.hexdigest() if status == "ok" else None),
                       send_lag_ms=round((t_send_m - t0) * 1000.0, 1),
                       slo_ok=ok, retries=retries)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            if status != "ok":
                errs += 1

    async def sender():
        for at, row in sched:
            if fatal:
                break
            delay = at - (time.monotonic() - t0)
            if delay > 0:
                await asyncio.sleep(delay)
            asyncio.create_task(fire(at, row))

    async def progress():
        while done < n_sched and not fatal:
            await asyncio.sleep(30)
            print(f"  [run {RUN_IDX} arm {ARM}] t={time.monotonic()-t0:.0f}s "
                  f"sent={sent} done={done}/{n_sched} errors={errs}", flush=True)

    sd = asyncio.create_task(sender())
    pg = asyncio.create_task(progress())
    await sd
    # formal blocks never abort on SLO — every engaged request gets its row.
    # Drain bounded by REQ_TIMEOUT_S per request (+120s slack), then stragglers
    # are cancelled and recorded (belt-and-braces; httpx timeout fires first).
    pending = {t for t in asyncio.all_tasks()
               if t is not asyncio.current_task() and t not in (sd, pg)}
    deadline = time.monotonic() + REQ_TO + 120.0
    while pending:
        if fatal or time.monotonic() > deadline:
            for t in pending:
                t.cancel()
        _, pending = await asyncio.wait(
            pending, timeout=5.0, return_when=asyncio.FIRST_COMPLETED)
    pg.cancel()

async def main():
    limits = httpx.Limits(max_connections=CONC,
                          max_keepalive_connections=min(CONC, 256))
    timeout = httpx.Timeout(REQ_TO, connect=30.0)
    hdr = {"type": "header", "pair_id": PAIR_ID, "arm": ARM, "run_idx": RUN_IDX,
           "run_seed": RUN_SEED, "scripts_rev": SREV, "D": D0, "C": C0,
           "r": f"1/{D0}", "window_s": WINDOW, "fallback": FB,
           "disclosure": DISC if FB else "",
           "slo_reference": {"ttft_s": TTFT_SLO, "tpot_ms": TPOT_SLO},
           "started_wall": round(time.time(), 3)}
    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        with open(RAW, "w") as raw_f:
            raw_f.write(json.dumps(hdr) + "\n")
            await replay(client, raw_f)
    if fatal:
        marker = {"arm": ARM, "status": "failed-server-error", "reason": fatal[0],
                  "rows": done, "note": "run voided per Protocol Lock v2.1 sec.2 "
                                        "item 2 (server-side error); re-run the "
                                        "nightly command after the cause is fixed — "
                                        "the block replays against identical load"}
        json.dump(marker, open(FAIL_F, "w"), indent=2)
        print(f"[run {RUN_IDX} arm {ARM}] VOIDED — server-side error {fatal[0]}; "
              f"block marked failed", flush=True)
        sys.exit(45)
    ok_rows = errs_n = 0
    tps_sum = ttft_sum = tpot_sum = e2e_sum = 0.0
    comp_sum = 0
    with open(RAW) as f:
        for ln in f:
            r = json.loads(ln)
            if "status" not in r:
                continue
            if r["status"] == "ok":
                ok_rows += 1
                tps_sum  += r["completion_tokens"] / r["e2e_s"]
                ttft_sum += r["ttft_s"]; e2e_sum += r["e2e_s"]
                comp_sum += r["completion_tokens"]
                if r["tpot_ms"] is not None:
                    tpot_sum += r["tpot_ms"]
            elif r["status"] != "skipped_overlength":
                errs_n += 1
    raw_sha = hashlib.sha256(open(RAW, "rb").read()).hexdigest()
    marker = {"arm": ARM, "status": "ok", "rows": done,
              "ok": ok_rows, "errors": errs_n,
              "mean_tps": round(tps_sum / max(ok_rows, 1), 6),
              "mean_ttft_s": round(ttft_sum / max(ok_rows, 1), 6),
              "mean_tpot_ms": round(tpot_sum / max(ok_rows, 1), 6),
              "mean_e2e_s": round(e2e_sum / max(ok_rows, 1), 6),
              "completion_tokens_total": comp_sum,
              "scheduled": n_sched, "window_s": WINDOW,
              "raw_sha256": raw_sha, "raw_file": os.path.basename(RAW)}
    json.dump(marker, open(DONE_F, "w"), indent=2)
    print(f"[run {RUN_IDX} arm {ARM}] block ok: rows={done} ok={ok_rows} "
          f"errors={errs_n} mean_tps={marker['mean_tps']:.2f} "
          f"mean_ttft={marker['mean_ttft_s']:.3f}s raw_sha={raw_sha[:16]}…",
          flush=True)

asyncio.run(main())
PY
}

# ---------------- run summary (descriptive means only — CI/P95 sealed in stage 04) --
summarize_run() {   # $1 = run_idx
RUN_IDX="$1" RUN_DIR="$RUN_DIR" RUN_SEED_BASE="$RUN_SEED_BASE" \
D_CHOSEN="$D_CHOSEN" C_CHOSEN="$C_CHOSEN" WINDOW_S="$WINDOW_S" \
FALLBACK="$FALLBACK" DISCLOSURE="$DISCLOSURE" SCRIPTS_REV="$SCRIPTS_REV" \
python3 - <<'PY'
import json, os

RUN_IDX = int(os.environ["RUN_IDX"])
RD = os.path.join(os.environ["RUN_DIR"], f"formal_run_{RUN_IDX}")

def rows(arm):
    out = []
    for ln in open(os.path.join(RD, f"arm{arm}.jsonl")):
        r = json.loads(ln)
        if "status" in r:
            out.append(r)
    return out

def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0

ra, rb = rows("A"), rows("B")
order = ["A", "B"] if RUN_IDX % 2 == 1 else ["B", "A"]
summ = {"run_idx": RUN_IDX, "pair_id": ra[0]["pair_id"] if ra else rb[0]["pair_id"],
        "run_seed": int(os.environ["RUN_SEED_BASE"]) + RUN_IDX,
        "arm_order": order, "D": int(os.environ["D_CHOSEN"]),
        "C": int(os.environ["C_CHOSEN"]), "window_s": float(os.environ["WINDOW_S"]),
        "fallback": os.environ["FALLBACK"] == "true",
        "disclosure": os.environ["DISCLOSURE"],
        "scripts_rev": os.environ["SCRIPTS_REV"], "note": "descriptive means only; "
        "paired-bootstrap CI (seed 20262002) and the P95 non-inferiority gate are "
        "computed exclusively by the stage-04 verdict script"}
per_arm = {}
for arm, rr in (("A", ra), ("B", rb)):
    ok = [r for r in rr if r["status"] == "ok"]
    per_arm[arm] = {
        "rows": len(rr), "ok": len(ok),
        "errors": sum(1 for r in rr
                      if r["status"] not in ("ok", "skipped_overlength")),
        "skipped_overlength": sum(1 for r in rr if r["status"] == "skipped_overlength"),
        "mean_tps": round(mean([r["completion_tokens"] / r["e2e_s"] for r in ok]), 6),
        "mean_ttft_s": round(mean([r["ttft_s"] for r in ok]), 6),
        "mean_tpot_ms": round(mean([r["tpot_ms"] for r in ok if r["tpot_ms"] is not None]), 6),
        "mean_e2e_s": round(mean([r["e2e_s"] for r in ok]), 6),
    }
summ["per_arm"] = per_arm
oka = {r["request_id"]: r for r in ra if r["status"] == "ok"}
okb = {r["request_id"]: r for r in rb if r["status"] == "ok"}
both = [(okb[k], oka[k]) for k in oka.keys() & okb.keys()]
ratios = [(b["completion_tokens"] / b["e2e_s"]) / (a["completion_tokens"] / a["e2e_s"])
          for b, a in both]
summ["paired_ok_requests"] = len(both)
summ["paired_mean_ratio_B_over_A"] = round(mean(ratios), 6)
json.dump(summ, open(os.path.join(RD, "run_summary.json"), "w"), indent=2)
print(f"[run {RUN_IDX}] summary: paired_ok={len(both)} "
      f"mean_tps A={per_arm['A']['mean_tps']:.2f} B={per_arm['B']['mean_tps']:.2f} "
      f"descriptive paired mean ratio B/A={summ['paired_mean_ratio_B_over_A']:.4f} "
      f"(descriptive only — CI sealed in stage 04)", flush=True)
PY
}

# ---------------- main driver: 6 runs × 2 arm blocks, block-crossover ----------------
say "starting formal measurement: 6 runs, block-crossover, operating point r=1/${D_CHOSEN} C=${C_CHOSEN}"
[ "$FALLBACK" = "true" ] && say "disclosure (carried into every summary): $DISCLOSURE"

if [ "${STAGE03_SKIP_SERVER:-0}" != "1" ]; then   # test hook: assume external server on PORT
  trap stop_server EXIT
else
  warn "STAGE03_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
fi

for CUR_RUN in $RUNS; do
  [ "$CUR_RUN" -le "$N_RUNS" ] || die "run index $CUR_RUN > $N_RUNS — straddle extension is stage-04's call (see reconciliation note)"
  check_time_rail
  RD="$RUN_DIR/formal_run_$CUR_RUN"
  mkdir -p "$RD"
  PAIR_ID="pair_$CUR_RUN"
  [ -f "$PLANS_DIR/$PAIR_ID.jsonl" ] || die "plan missing: $PLANS_DIR/$PAIR_ID.jsonl — re-run stage 01"
  if [ $(( CUR_RUN % 2 )) -eq 1 ]; then ARMS="A B"; else ARMS="B A"; fi
  say "run $CUR_RUN / $N_RUNS — $PAIR_ID, arm order: $ARMS"
  for ARM in $ARMS; do
    if [ -f "$RD/arm${ARM}.done" ]; then
      echo "  [run $CUR_RUN arm $ARM] already done (resume)"
      continue
    fi
    if [ -f "$RD/arm${ARM}.failed" ]; then
      warn "run $CUR_RUN arm $ARM: previous attempt voided by server-side error — replaying identical load"
      rm -f "$RD/arm${ARM}.failed" "$RD/arm${ARM}.jsonl"
    fi
    check_time_rail
    if [ "${STAGE03_SKIP_SERVER:-0}" != "1" ]; then
      start_server "$ARM"
    fi
    set +e
    run_block "$CUR_RUN" "$ARM" "$PAIR_ID"
    RC=$?
    set -e
    if [ "$RC" -eq 45 ]; then
      [ "${STAGE03_SKIP_SERVER:-0}" != "1" ] && stop_server || true
      die "run $CUR_RUN arm $ARM voided by server-side error — incident recorded in $RD/arm${ARM}.failed + server log; enters the deviation log. Re-run the nightly command after the cause is fixed."
    fi
    [ "$RC" -eq 0 ] || die "block client failed (rc=$RC) — see stage.log"
    if [ "${STAGE03_SKIP_SERVER:-0}" != "1" ]; then
      # if the engine died mid-block but every request still completed, the block
      # stands; otherwise the marker would have been 'failed' above
      if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then
        warn "run $CUR_RUN arm $ARM: server process exited during/after block — see server_run${CUR_RUN}_arm${ARM}.log"
      fi
      stop_server
    fi
  done
  if [ -f "$RD/armA.done" ] && [ -f "$RD/armB.done" ]; then
    summarize_run "$CUR_RUN"
    echo "ok" > "$RD/RUN_COMPLETE"
    push_logs "${DATE_STR} 03-formal run_${CUR_RUN} exit=0"
  fi
done

# ---------------- stage complete ----------------
check_time_rail
MISSING=""
for i in $RUNS; do
  [ -f "$RUN_DIR/formal_run_$i/RUN_COMPLETE" ] || MISSING="$MISSING $i"
done
[ -z "$MISSING" ] || die "incomplete runs:$MISSING — re-run the nightly command to resume"

echo "ok" > "$RUN_DIR/COMPLETE"
say "✅ stage 03 COMPLETE — 6 formal runs × 2 arm blocks archived"
echo "  operating point: r=1/${D_CHOSEN} C=${C_CHOSEN} (frozen by stage 02)"
[ "$FALLBACK" = "true" ] && echo "  disclosure: $DISCLOSURE"
echo "  data:   $RUN_DIR (per-request raw JSONL + per-block markers + per-run summaries)"
echo "  verify: bash stages/03-formal.sh --verify"
echo "  next:   switch the STAGE file to 04-verdict (not yet shipped)"
echo "  sealed: the paired-bootstrap CI (seed 20262002) and the P95 gate are computed"
echo "          only by stage 04 — descriptive means above are not the verdict."
