#!/usr/bin/env bash
# ============================================================
# Stage 05 · L5 blind quality gate, concurrency edition (Pilot 002)
#
# Protocol Lock v2.1 L5: does FP8 cost output quality when
# generation happens in SERVING MODE under declared concurrency?
# Method (locked):
#   1. Frozen evaluation set: the Pilot 001 150-item set, reused
#      BY HASH (728b2f83…5cf7d) — constructing a new set would
#      constitute a new experiment. Located in the pilot-logs
#      archive (2026-10-06/06-quality-gate), hash-verified, then
#      copied into this run dir with provenance recorded.
#   2. Generation: OpenAI-compatible serving mode (vllm serve),
#      temperature=0, concurrency 8, natural stopping (the
#      quality gate does NOT use ignore_eos — L2). Arm A = BF16
#      defaults; arm B = --quantization fp8. Prefix caching OFF.
#      Pre-registered disclosure (L5): under continuous batching,
#      floating-point reduction order makes outputs
#      non-bit-deterministic; the gate compares judged text
#      quality, never textual identity.
#   3. Blind judging: same 3-axis 0-10 rubric as Pilot 001
#      (byte-identical judge prompt), blind seed 20261011
#      decides per item which arm appears as "response 1".
#      Judge policy (unchanged): non-Qwen-family external judge
#      (family conflict of interest exclusion); probe order
#      declared below; first reachable model judges ALL items.
#   4. Verdict (pre-registered point estimates): PASS iff the
#      pooled delta (B - A) and every per-axis delta are >= -0.1.
#      Bootstrap CI is DESCRIPTIVE ONLY (seed 20261012, declared).
#
# Anchors (L1): Qwen2.5-14B-Instruct revision
#   cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8, vLLM pinned 0.31.0,
#   one L40S.
#
# Budget guards (K8): stage wall clock capped (MAX_SECONDS);
# judge spend capped (BUDGET_USD; expected actual < $1).
#
# Resume: every phase skips work already archived. Re-running the
# nightly command after an interruption resumes where it left off.
#
# Verify entry: bash stages/05-quality-gate.sh --verify [run_dir]
# Recomputes the verdict from the archived logs only (no network,
# no GPU); output must match the archived verdict_q.txt.
#
# Test hooks (sandbox only, never set in production):
#   STAGE05_SKIP_SERVER, PORT, OR_BASE_URL, STAGE05_FROZEN_JSONL,
#   KEY_FILE, STAGE05_OUT_DIR, MAX_SECONDS, BUDGET_USD
# ============================================================
set -euo pipefail

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot002}"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE_NAME="05-quality-gate"

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
VLLM_PINNED="0.31.0"                                   # L1 pinned
GPU_EXPECT="L40S"
MAX_MODEL_LEN=32768
FROZEN_SHA="728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d"  # L5 reused by hash
BLIND_SEED=20261011                                    # L5 pinned (new vs Pilot 001)
N_ITEMS=150
TOL=0.1                                                # L5 tolerance
GEN_CONC=8                                             # L5 declared serving concurrency
MAX_SECONDS="${MAX_SECONDS:-14400}"                    # K8 wall-clock cap (~4 h)
BUDGET_USD="${BUDGET_USD:-45}"                         # K8 judge spend cap
BOOT_SEED=20261012                                     # descriptive CI only, declared
BOOT_N=100000
KEY_FILE="${KEY_FILE:-$HOME/pilot-env/openrouter-key}"
PORT="${PORT:-8000}"                                   # env override is a test hook only

note() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\n\033[1;31m[stage05][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

set_paths() {
  RUN_DIR="$1"
  FROZEN_JSONL="$RUN_DIR/frozen_set.jsonl"
  GEN_A_JSONL="$RUN_DIR/gen_A.jsonl"
  GEN_B_JSONL="$RUN_DIR/gen_B.jsonl"
  BLIND_JSONL="$RUN_DIR/blind_map.jsonl"
  JUDGE_RAW_JSONL="$RUN_DIR/judge_raw.jsonl"
  VERDICT_TXT="$RUN_DIR/verdict_q.txt"
}

run_verdict() {
  RUN_DIR="$RUN_DIR" FROZEN_JSONL="$FROZEN_JSONL" GEN_A_JSONL="$GEN_A_JSONL" \
  GEN_B_JSONL="$GEN_B_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" VERDICT_TXT="$VERDICT_TXT" \
  N_ITEMS="$N_ITEMS" TOL="$TOL" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" \
  BLIND_SEED="$BLIND_SEED" GEN_CONC="$GEN_CONC" python3 - <<'PY'
import hashlib, json, os, statistics

RUN_DIR = os.environ["RUN_DIR"]
FROZEN  = os.environ["FROZEN_JSONL"]
GEN_A   = os.environ["GEN_A_JSONL"]
GEN_B   = os.environ["GEN_B_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
VERDICTF= os.environ["VERDICT_TXT"]
N_ITEMS = int(os.environ["N_ITEMS"])
TOL     = float(os.environ["TOL"])
BSEED   = int(os.environ["BOOT_SEED"])
BN      = int(os.environ["BOOT_N"])
AXES    = ["correctness", "instruction_following", "clarity"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"

lines = ["STAGE 05 VERDICT — L5 BLIND QUALITY GATE (PILOT 002, serving-mode concurrency edition)",
         f"tolerance={TOL} (10-pt scale; pre-registered: quality degradation > {TOL} -> FAIL)",
         f"generation: serving mode, temperature=0, concurrency {os.environ['GEN_CONC']}, natural stopping",
         "disclosure (L5): under continuous batching, floating-point reduction order makes",
         "outputs non-bit-deterministic; this gate compares judged text quality, never identity.",
         f"blind seed={os.environ['BLIND_SEED']}; judge blinded to arm identity, judge model archived per row", ""]
for name, p in [("frozen_set.jsonl", FROZEN), ("gen_A.jsonl", GEN_A),
                ("gen_B.jsonl", GEN_B), ("judge_raw.jsonl", JRAW),
                ("blind_map.jsonl", os.path.join(RUN_DIR, "blind_map.jsonl"))]:
    lines.append(f"  {name}: sha256={sha(p)}")

frozen = {json.loads(l)["request_id"]: json.loads(l) for l in open(FROZEN) if l.strip()}
rows = [json.loads(l) for l in open(JRAW) if l.strip()] if os.path.exists(JRAW) else []
lines += ["", f"judged items: {len(rows)} / {N_ITEMS}"]

if len(rows) < N_ITEMS:
    lines += ["", f"REFUSED: quality gate incomplete ({len(rows)}/{N_ITEMS}) — verdict sealed by protocol.",
              "Re-run the stage to resume judging; no PASS/FAIL is computed on partial data."]
    open(VERDICTF, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

def load_gen(p):
    return {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()}
gA, gB = load_gen(GEN_A), load_gen(GEN_B)

jmodels = sorted({r["judge_model"] for r in rows})
lines += ["", f"judge model(s) used: {', '.join(jmodels)}"]

# ---- unblind ----
per_item = []
for r in rows:
    rid = r["request_id"]
    sA = r["scores_r1"] if r["a_is_response_1"] else r["scores_r2"]
    sB = r["scores_r2"] if r["a_is_response_1"] else r["scores_r1"]
    per_item.append((rid, frozen[rid]["form"], {a: (sA[a], sB[a]) for a in AXES}))

lines += ["", "[per-axis results: mean over 150 items, 10-pt scale]"]
axis_delta = {}
for a in AXES:
    mA = statistics.mean(sc[a][0] for _, _, sc in per_item)
    mB = statistics.mean(sc[a][1] for _, _, sc in per_item)
    axis_delta[a] = mB - mA
    lines.append(f"  {a:22s}: A(bf16)={mA:.3f}  B(fp8)={mB:.3f}  delta={mB-mA:+.3f}")

item_delta = [statistics.mean(sc[a][1] - sc[a][0] for a in AXES) for _, _, sc in per_item]
overall = statistics.mean(item_delta)
lines += ["", f"[overall] pooled delta (B - A): {overall:+.3f}"]

gate_ok = overall >= -TOL and all(d >= -TOL for d in axis_delta.values())
lines += ["", f"criterion: overall delta >= -{TOL} AND every axis delta >= -{TOL}  ->  {'PASS' if gate_ok else 'FAIL'}"]

ident = sum(1 for rid, _, _ in per_item if gA[rid]["output_text"] == gB[rid]["output_text"])
lines += ["", f"[descriptive] textually identical outputs across arms: {ident}/{N_ITEMS}",
          "[descriptive] per-form pooled delta (B - A):"]
for form in ("doc_qa", "code_completion", "summarization"):
    v = [statistics.mean(sc[a][1] - sc[a][0] for a in AXES) for _, f, sc in per_item if f == form]
    lines.append(f"  {form:16s}: {statistics.mean(v):+.3f} (n={len(v)})")

import numpy as np
vals = np.array(item_delta)
rng = np.random.default_rng(BSEED)
means = rng.choice(vals, size=(BN, len(vals)), replace=True).mean(axis=1)
lo, hi = np.percentile(means, [2.5, 97.5])
lines += ["", f"[descriptive] 95% bootstrap CI of overall delta: [{lo:+.3f}, {hi:+.3f}] "
              f"(seed={BSEED}, resamples={BN}; the gate decision uses the point estimates above, per protocol)"]

lines += ["", "This file is reproducible from the archived logs alone: bash stages/05-quality-gate.sh --verify <run_dir>"]
open(VERDICTF, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
}

# ---------- --verify ----------
# Copy the archived inputs to a temp dir, recompute there, byte-compare the
# verdict against the archive. The archive itself is never rewritten.
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  if [ -z "$D" ]; then D="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$D" ] && [ -f "$D/verdict_q.txt" ] || { echo "VERIFY: usage: --verify <run_dir> (no verdict archive found)"; exit 1; }
  note "verify: recomputing verdict from archived logs in $D (no network, no GPU)"
  TMPD="$(mktemp -d)"
  for f in frozen_set.jsonl gen_A.jsonl gen_B.jsonl blind_map.jsonl judge_raw.jsonl; do
    cp "$D/$f" "$TMPD/$f"
  done
  set_paths "$TMPD"
  run_verdict > /dev/null
  cmp -s "$TMPD/verdict_q.txt" "$D/verdict_q.txt" \
    && { echo "VERIFY: verdict_q.txt byte-identical"; echo "VERIFY: ALL CHECKS PASSED"; rm -rf "$TMPD"; exit 0; } \
    || { diff "$D/verdict_q.txt" "$TMPD/verdict_q.txt" | head -20; echo "VERIFY: MISMATCH — investigate before trusting the archive" >&2; exit 1; }
fi

# ---------- run bookkeeping: resume an incomplete run dir ----------
note "0. run bookkeeping"
if [ -n "${STAGE05_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE05_OUT_DIR"; mkdir -p "$RUN_DIR"
else
  LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
    echo "STAGE 05 already COMPLETE: $LATEST"
    echo "verdict: $LATEST/verdict_q.txt  (to recompute from logs: bash stages/05-quality-gate.sh --verify)"
    exit 0
  fi
  RUN_DIR=""
  for cand in $(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null); do
    if [ ! -f "$cand/COMPLETE" ]; then RUN_DIR="$cand"; echo "resuming incomplete run dir: $RUN_DIR"; break; fi
  done
  if [ -z "$RUN_DIR" ]; then
    RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE_NAME/run_1"
    SUFFIX=2
    while [ -e "$RUN_DIR" ]; do RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE_NAME/run_1-r${SUFFIX}"; SUFFIX=$((SUFFIX+1)); done
    mkdir -p "$RUN_DIR"
    echo "new run dir: $RUN_DIR"
  fi
fi
set_paths "$RUN_DIR"

# ---------- preflight ----------
note "1. time / host / GPU / engine anchors (L1)"
date -u
hostname || true
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
echo "scripts_rev=$GIT_REV"
if [ "${STAGE05_SKIP_SERVER:-0}" != "1" ]; then
  python3 - <<PY
import sys
try:
    import vllm
    assert vllm.__version__ == "$VLLM_PINNED", f"vLLM {vllm.__version__} != pinned $VLLM_PINNED (L1)"
    print("vllm:", vllm.__version__, "(pinned OK)")
except ImportError:
    sys.exit("No module named 'vllm' — install vllm==$VLLM_PINNED first (L1 pin)")
PY
fi
if [ "${STAGE05_SKIP_SERVER:-0}" != "1" ]; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  [[ "$GPU_NAME" == *"$GPU_EXPECT"* ]] || die "expected $GPU_EXPECT, found '$GPU_NAME' (hardware boundary, L3)"
  echo "gpu: $GPU_NAME"
fi

if [ ! -f "$KEY_FILE" ]; then
  echo "REFUSED: judge key not found at $KEY_FILE"
  echo "Store the OpenRouter key of the effiq-judge account first (same pattern as the GitHub token):"
  echo '  mkdir -p ~/pilot-env && chmod 700 ~/pilot-env && cat > ~/pilot-env/openrouter-key'
  echo '  (paste the key, Enter, Ctrl+D)  then:  chmod 600 ~/pilot-env/openrouter-key'
  exit 1
fi
PERMS=$(stat -c %a "$KEY_FILE" 2>/dev/null || echo "?")
[ "$PERMS" = "600" ] || echo "WARNING: $KEY_FILE permissions are $PERMS (expected 600)"

python3 -c "import httpx" 2>/dev/null || pip install -q httpx   # generation client dependency
echo "banner: L5 BLIND QUALITY GATE — Pilot 002 (serving mode, concurrency $GEN_CONC)"
START_TS=$(date +%s)

# ---------- phase 2: frozen set, reused by hash from the Pilot 001 archive ----------
note "2. frozen evaluation set (reused by hash $FROZEN_SHA)"
if [ -n "${STAGE05_FROZEN_JSONL:-}" ]; then
  cp "${STAGE05_FROZEN_JSONL}" "$FROZEN_JSONL"
  echo "TEST HOOK: frozen set overridden from $STAGE05_FROZEN_JSONL (hash assert skipped)"
elif [ ! -f "$FROZEN_JSONL" ]; then
  SRC_FROZEN="$(ls -t "$LOGS_DIR"/*/06-quality-gate/run_*/frozen_set.jsonl 2>/dev/null | head -1 || true)"
  [ -n "$SRC_FROZEN" ] || die "Pilot 001 frozen set not found in the logs archive (expected under */06-quality-gate/run_*/)"
  ACTUAL_SHA=$(sha256sum "$SRC_FROZEN" | cut -d' ' -f1)
  [ "$ACTUAL_SHA" = "$FROZEN_SHA" ] || die "frozen set hash mismatch: $ACTUAL_SHA != $FROZEN_SHA — refusing to judge a different set"
  cp "$SRC_FROZEN" "$FROZEN_JSONL"
  echo "reused from: $SRC_FROZEN (sha256 verified $FROZEN_SHA)"
else
  ACTUAL_SHA=$(sha256sum "$FROZEN_JSONL" | cut -d' ' -f1)
  [ "$ACTUAL_SHA" = "$FROZEN_SHA" ] || die "run-dir frozen set corrupted: $ACTUAL_SHA != $FROZEN_SHA"
  echo "frozen set already in run dir (sha256 verified)"
fi
N_FROZEN=$(wc -l < "$FROZEN_JSONL")
[ "$N_FROZEN" -eq "$N_ITEMS" ] || die "frozen set row count $N_FROZEN != $N_ITEMS"

# ---------- vLLM server lifecycle (same machinery as stage 03) ----------
start_server() {   # $1 = arm (A|B)
  local arm="$1"
  # 2026-10-08 lesson (stage-03 incident): never reference a variable being
  # bound in the same `local` statement — set -u expands all RHS words first.
  local slog="$RUN_DIR/server_arm${arm}.log"
  local extra=""
  [ "$arm" = "B" ] && extra="--quantization fp8"
  echo "starting arm ${arm} server ($([ "$arm" = B ] && echo 'FP8 dynamic' || echo 'BF16 defaults'); prefix caching OFF)"
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
  echo "arm ${arm} server healthy after ${waited}s"
  echo "server_argv: vllm serve $MODEL --revision $MODEL_REV --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN $extra --port $PORT" \
    | sed 's/  */ /g' > "$RUN_DIR/server_argv_arm${arm}.txt"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

# ---------- phase 3/4: serving-mode generation, one arm per invocation ----------
generate_arm() {   # $1 = arm (A|B)
  local arm="$1" gen_jsonl
  [ "$arm" = "A" ] && gen_jsonl="$GEN_A_JSONL" || gen_jsonl="$GEN_B_JSONL"
  note "generation: arm $arm ($([ "$arm" = A ] && echo BF16 || echo FP8), serving mode, concurrency $GEN_CONC)"
  if [ "${STAGE05_SKIP_SERVER:-0}" != "1" ]; then
    start_server "$arm"
    trap stop_server EXIT
  else
    echo "STAGE05_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
  fi
  FROZEN_JSONL="$FROZEN_JSONL" GEN_JSONL="$gen_jsonl" ARM="$arm" \
  MODEL="$MODEL" MODEL_REV="$MODEL_REV" PORT="$PORT" GEN_CONC="$GEN_CONC" \
  MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" GIT_REV="$GIT_REV" python3 - <<'PY'
import asyncio, datetime, hashlib, json, os, time

import httpx

MODEL   = os.environ["MODEL"]
FROZEN  = os.environ["FROZEN_JSONL"]
GEN     = os.environ["GEN_JSONL"]
ARM     = os.environ["ARM"]
PORT    = os.environ["PORT"]
CONC    = int(os.environ["GEN_CONC"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])
REQ_TO  = 900.0   # per-request bound, same as stage 03

frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in frozen if r["request_id"] not in done]
print(f"arm {ARM}: {len(done)} already generated, {len(todo)} to go", flush=True)
if not todo:
    print(f"arm {ARM}: nothing to do — resume complete", flush=True)
    raise SystemExit(0)

async def main():
    gate = asyncio.Semaphore(CONC)
    lock = asyncio.Lock()
    n_done = 0
    async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{PORT}",
                                 timeout=httpx.Timeout(REQ_TO, connect=30.0)) as client:
        async def one(rec):
            nonlocal n_done
            async with gate:
                body = dict(model=MODEL, prompt=rec["prompt"],
                            temperature=0, max_tokens=rec["max_tokens"])
                t0 = time.time()
                # natural stopping: no ignore_eos (L2/L5 — judged outputs are produced naturally)
                r = await client.post("/v1/completions", json=body)
                r.raise_for_status()
                wall = time.time() - t0
                resp = r.json()
                text = resp["choices"][0]["text"]
                usage = resp.get("usage", {})
                row = dict(request_id=rec["request_id"], arm=ARM,
                           form=rec["form"], tier_target=rec["tier_target"],
                           max_tokens=rec["max_tokens"],
                           prompt_tokens=usage.get("prompt_tokens", 0),
                           output_tokens=usage.get("completion_tokens", 0),
                           wall_s=round(wall, 3),
                           output_text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                           output_text=text,
                           model=MODEL, model_revision=os.environ["MODEL_REV"],
                           scripts_rev=os.environ["GIT_REV"],
                           ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                async with lock:
                    with open(GEN, "a") as fg:
                        fg.write(json.dumps(row, sort_keys=True) + "\n")
                    n_done += 1
                    if n_done % 10 == 0 or n_done == 1:
                        print(f"  arm {ARM}: {len(done)+n_done}/{len(frozen)} "
                              f"(last: {rec['request_id']}, {row['output_tokens']} tok, {wall:.1f}s)", flush=True)
        await asyncio.gather(*(one(rec) for rec in todo))

asyncio.run(main())
print(f"arm {ARM} generation phase done", flush=True)
PY
  [ "${STAGE05_SKIP_SERVER:-0}" != "1" ] && stop_server || true
}

generate_arm A
generate_arm B

# ---------- phase 5: blind judging via OpenRouter ----------
note "5. blind judging (judge sees no arm labels; blind seed $BLIND_SEED)"
FROZEN_JSONL="$FROZEN_JSONL" GEN_A_JSONL="$GEN_A_JSONL" GEN_B_JSONL="$GEN_B_JSONL" \
BLIND_JSONL="$BLIND_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" BLIND_SEED="$BLIND_SEED" \
KEY_FILE="$KEY_FILE" BUDGET_USD="$BUDGET_USD" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" \
OR_BASE_URL="${OR_BASE_URL:-https://openrouter.ai/api/v1}" GIT_REV="$GIT_REV" python3 - <<'PY'
import hashlib, json, os, time, datetime, random
import urllib.request, urllib.error

FROZEN  = os.environ["FROZEN_JSONL"]
GEN_A   = os.environ["GEN_A_JSONL"]
GEN_B   = os.environ["GEN_B_JSONL"]
BLINDF  = os.environ["BLIND_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
BLSEED  = int(os.environ["BLIND_SEED"])
KEYF    = os.environ["KEY_FILE"]
BUDGET  = float(os.environ["BUDGET_USD"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])
ORBASE  = os.environ["OR_BASE_URL"].rstrip("/")
AXES    = ["correctness", "instruction_following", "clarity"]

# Judge model policy (documented, pre-registered; unchanged from Pilot 001):
#   - OpenAI / Anthropic / Google models are NOT reachable: the billing region
#     of this account is blocked from those providers by OpenRouter policy.
#   - Qwen-family judges are excluded BY DESIGN: a Qwen judge scoring Qwen
#     outputs would be a family conflict of interest.
#   - Probe order below (carried over from Pilot 001); first model that
#     answers becomes the judge and its identity is archived with every
#     judged row. Prices are USD per 1M tokens (input/output), used for the
#     budget guard only, not for any verdict math.
CANDIDATES = [
    ("deepseek/deepseek-chat-v3-0324", 0.29, 1.14),
    ("deepseek/deepseek-chat-v3.1",    0.25, 0.95),
    ("deepseek/deepseek-v3.1-terminus",0.27, 1.00),
    ("z-ai/glm-4.6",                   0.43, 1.75),
]
FALLBACK_PRICE = (1.00, 3.00)

if not os.path.exists(KEYF):
    print(f"REFUSED: judge key file missing: {KEYF}")
    raise SystemExit(1)
KEY = open(KEYF).read().strip()
if not KEY.startswith("sk-or-") and "openrouter.ai" in ORBASE:
    print("REFUSED: key file does not look like an OpenRouter key (expected sk-or-... prefix)")
    raise SystemExit(1)

def call_api(model, messages, max_tokens, timeout=120):
    body = json.dumps(dict(model=model, messages=messages, temperature=0,
                           max_tokens=max_tokens)).encode()
    req = urllib.request.Request(
        f"{ORBASE}/chat/completions", data=body,
        headers={"Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json",
                 "HTTP-Referer": "https://github.com/effiq/pilot002",
                 "X-Title": "effiq-pilot002-quality-gate"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# ---- probe judge model ----
judge_model, pin, pout = None, None, None
for cand, cin, cout in CANDIDATES:
    try:
        resp = call_api(cand, [dict(role="user", content="Reply with the single word: ok")], max_tokens=4, timeout=60)
        txt = resp["choices"][0]["message"]["content"]
        judge_model, pin, pout = cand, cin, cout
        print(f"judge model selected: {cand} (probe ok)")
        break
    except Exception as e:
        print(f"judge candidate {cand}: unavailable ({type(e).__name__}: {e})")
if judge_model is None:
    print("REFUSED: no judge model reachable — check key balance/region; nothing judged.")
    raise SystemExit(1)

# ---- load data ----
frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
def load_gen(p):
    return {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()}
gA, gB = load_gen(GEN_A), load_gen(GEN_B)

# ---- blind map (seeded, archived; the judge never learns which arm is which) ----
blind = {}
if os.path.exists(BLINDF):
    for l in open(BLINDF):
        if l.strip():
            r = json.loads(l); blind[r["request_id"]] = r["a_is_response_1"]
else:
    rng = random.Random(BLSEED)
    with open(BLINDF, "w") as fb:
        for rec in frozen:
            v = rng.random() < 0.5
            blind[rec["request_id"]] = v
            fb.write(json.dumps(dict(request_id=rec["request_id"], a_is_response_1=v), sort_keys=True) + "\n")
        fb.flush()
    print(f"blind map built (seed={BLSEED}): {len(blind)} items")

judged = {}
if os.path.exists(JRAW):
    for l in open(JRAW):
        if l.strip():
            r = json.loads(l); judged[r["request_id"]] = r

def est_cost(model, ptoks, ctoks):
    cin, cout = FALLBACK_PRICE
    for cand, i_, o_ in CANDIDATES:
        if cand == model: cin, cout = i_, o_
    return (ptoks * cin + ctoks * cout) / 1e6

spent = sum(est_cost(r["judge_model"], r.get("prompt_tokens", 0), r.get("completion_tokens", 0))
            for r in judged.values())
print(f"judge resume: {len(judged)} already judged, est. spent so far ${spent:.3f} (budget guard ${BUDGET:.0f})")

SYSTEM = ("You are an impartial, strict evaluator of AI assistant outputs. You compare two "
          "responses to the same user prompt and score each on three axes. Be objective and "
          "consistent across items. Output ONLY valid JSON, no markdown, no commentary.")
TEMPLATE = """[USER PROMPT]
{prompt}

[RESPONSE 1]
{r1}

[RESPONSE 2]
{r2}

Score each response on three axes, integers 0-10:
- correctness: factual/technical correctness relative to what the prompt asks.
- instruction_following: does it do what was asked, completely, without missing parts or extraneous content.
- clarity: coherence, organization, fluency.

Return ONLY this JSON:
{{"response_1": {{"correctness": X, "instruction_following": Y, "clarity": Z}},
 "response_2": {{"correctness": X, "instruction_following": Y, "clarity": Z}}}}"""

def parse_scores(content):
    c = content.strip()
    if c.startswith("```"):
        c = c.strip("`")
        if c.lower().startswith("json"): c = c[4:]
    i, j = c.find("{"), c.rfind("}")
    obj = json.loads(c[i:j+1])
    out = {}
    for k in ("response_1", "response_2"):
        sc = obj[k]
        vals = {a: int(sc[a]) for a in AXES}
        if not all(0 <= v <= 10 for v in vals.values()): raise ValueError("score out of range")
        out[k] = vals
    return out

n_new, n_fail = 0, 0
with open(JRAW, "a") as fj:
    for rec in frozen:
        rid = rec["request_id"]
        if rid in judged or rid not in gA or rid not in gB:
            continue
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: judging aborted past {MAX_SEC}s; partial judge log preserved — re-run to resume")
            break
        if spent > BUDGET:
            print(f"BUDGET GUARD: est. spend ${spent:.2f} exceeds ${BUDGET:.0f}; aborting (owner decision required)")
            break
        r1, r2 = ((gA[rid]["output_text"], gB[rid]["output_text"]) if blind[rid]
                  else (gB[rid]["output_text"], gA[rid]["output_text"]))
        msgs = [dict(role="system", content=SYSTEM),
                dict(role="user", content=TEMPLATE.format(prompt=rec["prompt"], r1=r1, r2=r2))]
        ok = False
        for attempt, pause in enumerate((5, 15, 30)):
            try:
                resp = call_api(judge_model, msgs, max_tokens=300)
                content = resp["choices"][0]["message"]["content"]
                scores = parse_scores(content)
                u = resp.get("usage", {})
                row = dict(request_id=rid, judge_model=judge_model,
                           a_is_response_1=blind[rid],
                           scores_r1=scores["response_1"], scores_r2=scores["response_2"],
                           prompt_tokens=u.get("prompt_tokens", 0),
                           completion_tokens=u.get("completion_tokens", 0),
                           raw_content=content, scripts_rev=os.environ["GIT_REV"],
                           ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                fj.write(json.dumps(row, sort_keys=True) + "\n"); fj.flush()
                spent += est_cost(judge_model, row["prompt_tokens"], row["completion_tokens"])
                n_new += 1; ok = True
                if n_new % 10 == 0 or n_new == 1:
                    print(f"  judged {rid} ({len(judged)+n_new}/{len(frozen)}), est. spent ${spent:.3f}")
                break
            except Exception as e:
                print(f"  judge error on {rid} (attempt {attempt+1}): {type(e).__name__}: {e}")
                time.sleep(pause)
        if not ok:
            n_fail += 1
            print(f"  {rid}: all retries failed — left for next resume")

print(f"judge phase done: new={n_new} failed={n_fail} total_judged={len(judged)+n_new}/{len(frozen)} est_spent=${spent:.3f}")
PY

# ---------- phase 6: verdict ----------
note "6. quality-gate verdict (recomputed from archived logs)"
set +e
run_verdict
RC_V=$?
set -e

# ---------- completeness gate ----------
NA=$(wc -l < "$GEN_A_JSONL" 2>/dev/null || echo 0)
NB=$(wc -l < "$GEN_B_JSONL" 2>/dev/null || echo 0)
NJ=$(wc -l < "$JUDGE_RAW_JSONL" 2>/dev/null || echo 0)
if [ "$NA" -ge "$N_ITEMS" ] && [ "$NB" -ge "$N_ITEMS" ] && [ "$NJ" -ge "$N_ITEMS" ] && [ "$RC_V" -eq 0 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  echo "STAGE 05 QUALITY GATE: COMPLETE (genA=$NA genB=$NB judged=$NJ; see verdict_q.txt)"
  echo "PILOT 002: both halves decided — see stage 04 verdict_p.txt and this stage's verdict_q.txt"
  exit 0
else
  echo "STAGE 05 QUALITY GATE: INCOMPLETE (genA=$NA genB=$NB judged=$NJ; no COMPLETE marker — re-run the same command to resume)"
  exit 1
fi
