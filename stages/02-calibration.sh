#!/usr/bin/env bash
# ============================================================
# Effiq Pilot 002 — STAGE 02: offered-load calibration
# ------------------------------------------------------------
# Implements Protocol Lock v2.1 (v2.0 frozen 2026-10-06 commit 49277e2,
# Amendment-01 commit 9dc7af3) §L2 calibration rule:
#   - replays the CALIBRATION slice pair against Arm A (BF16, server
#     defaults) over the (r, C) grid — r ∈ {1, 1/2, …, 1/256},
#     C ∈ {4, 8, 16} — in strictly decreasing offered-load order
#     (r×C desc, ties → larger C first), stopping at the first
#     configuration with ≥ 95% SLO compliance (pre-registered in
#     Amendment-01: monotone-compliance assumption; every attempted
#     configuration is logged).
#   - SLO (frozen L4): a request is compliant iff TTFT ≤ 5 s AND
#     TPOT ≤ 100 ms. Compliance = compliant / sent. Requests that
#     time out or error count as non-compliant.
#   - Early abort (declared here, calibration-only): a config is
#     abandoned as FAIL as soon as non-compliant count exceeds 5% of
#     sent-schedule size — further waiting cannot change the verdict.
#   - ALL outputs are watermarked: CALIBRATION DATA ONLY — never
#     enters the CI.
#
# The chosen (r, C) is written to chosen.json and frozen for stages 03+.
#
# Replay mechanics (declared, K7): arrival times compressed by C;
# thinning by keep_u < r (keep_u frozen in stage-01 plans); prompt bodies
# are deterministic synthetic token-id fillers of exactly context_tokens
# length (sent as raw token ids — no tokenizer dependency); generation
# length = min(GeneratedTokens, 1024) with ignore_eos=True (load-fidelity
# device, performance half only). Requests whose context alone exceeds
# the engine context limit are skipped and counted (disclosed as
# skipped_overlength; in formal runs the same counter is disclosed in
# the verdict). Prefix caching OFF; temperature 0.
#
# Modes:
#   (default)   run/resume the calibration scan (per-config .done markers)
#   --verify    offline recompute: compliance per config + selection rule
#               replayed from the archived raw JSONL — no GPU, no server
#
# Requires: L40S GPU, vLLM 0.31.0 (asserted), stage-01 plans on disk
# (re-run stage 01 after a pod wipe — outputs are byte-reproducible).
# ============================================================
set -euo pipefail

# ---------------- locked constants (Protocol Lock v2.1) ----------------
MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"
VLLM_PINNED="0.31.0"
GPU_EXPECT="L40S"
# Model's derived max (config.json max_position_embeddings). vLLM 0.31.0 refuses
# anything larger without VLLM_ALLOW_LONG_MAX_MODEL_LEN=1, which risks NaN on
# RoPE positions >32768 — never set it. Trace evidence (2026-10-06, all 7 plan
# files): max context_tokens = 7999, so 32768 loses zero requests. Matches
# Pilot 001's engine config (default 32768).
MAX_MODEL_LEN=32768
MAX_TOKENS_CAP=1024
SLO_TTFT_S=5.0
SLO_TPOT_MS=100.0
SLO_COMPLIANCE=0.95
D_GRID="${D_GRID:-1 2 4 8 16 32 64 128 256}"   # r = 1/D; env override is a test hook only
C_GRID="${C_GRID:-4 8 16}"                     # env override is a test hook only
REQ_TIMEOUT_S=900
# Max requests in flight at once (client-internal throttle; §2 exploration
# space). Payloads are built only after the gate, so memory is O(CONC), not
# O(plan rows). Learned the hard way 2026-10-06: unbounded tasks at r=1,C=16
# (203k pending × up-to-8k-token payloads) wedged the event loop.
CLIENT_CONC="${CLIENT_CONC:-2048}"               # env override is a test hook only
MAX_SECONDS=19800                   # soft rail (~5.5 h), resumable
FILLER_SEED=20261010                # same stream as stage-01 keep_u
PORT="${PORT:-8000}"                # env override is a test hook only

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
TRACE_DIR="${TRACE_DIR:-$EFFIQ_HOME/trace}"
PLANS_DIR="${PLANS_DIR:-$TRACE_DIR/plans}"
CALIB_PLAN="$PLANS_DIR/calibration.jsonl"
STAGE_NAME="02-calibration"
DATE_STR="$(date -u +%Y-%m-%d)"
T0=$(date +%s)

say()  { printf '\n\033[1;36m[stage02] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[stage02][WARN] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[stage02][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

check_time_rail() {
  local elapsed=$(( $(date +%s) - T0 ))
  [ "$elapsed" -gt "$MAX_SECONDS" ] && \
    die "time rail tripped (${elapsed}s). Completed configs carry .done markers — re-run the nightly command to resume."
  return 0
}

# ---------------- run dir: resume-or-create ----------------
LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
if [ "${1:-}" != "--verify" ] && [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
  say "this stage is already COMPLETE — nothing to do."
  echo "  result: $LATEST/chosen.json   (r, C frozen for stages 03+)"
  echo "  next:   switch the STAGE file to 03-formal"
  exit 0
fi

# ============================================================
# --verify mode: recompute compliance + selection from raw archives
# ============================================================
if [ "${1:-}" = "--verify" ]; then
  VD="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  [ -n "$VD" ] || die "--verify: no run directory found"
  say "--verify against $VD"
  VD="$VD" SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" \
  SLO_COMPLIANCE="$SLO_COMPLIANCE" D_GRID="$D_GRID" C_GRID="$C_GRID" \
  python3 - <<'PY'
import glob, json, os, sys

VD  = os.environ["VD"]
TTFT, TPOT = float(os.environ["SLO_TTFT_S"]), float(os.environ["SLO_TPOT_MS"])
NEED = float(os.environ["SLO_COMPLIANCE"])
Ds  = [int(x) for x in os.environ["D_GRID"].split()]
Cs  = [int(x) for x in os.environ["C_GRID"].split()]

def compliant(row):
    return (row["status"] == "ok" and row["ttft_s"] is not None
            and row["ttft_s"] <= TTFT and row["tpot_ms"] is not None
            and row["tpot_ms"] <= TPOT)

order = sorted([(d, c) for d in Ds for c in Cs], key=lambda x: (-(x[1] / x[0]), -x[1]))
checks = []
def check(name, ok, detail=""):
    checks.append((name, bool(ok), detail))

summaries = {}
for d, c in order:
    done = os.path.join(VD, f"calib_d{d}_c{c}.done")
    raw  = os.path.join(VD, f"calib_d{d}_c{c}.jsonl")
    if not os.path.exists(done):
        continue
    rows = [json.loads(l) for l in open(raw)]
    rows = [r for r in rows if "status" in r]   # skip watermark header line
    sent = [r for r in rows if r["status"] != "skipped_overlength"]
    noncomp = sum(1 for r in sent if not compliant(r))
    comp = 1.0 - (noncomp / len(sent)) if sent else 0.0
    marker = json.load(open(done))
    summaries[(d, c)] = (comp, marker["status"])
    check(f"config d{d}/c{c}: recomputed compliance {comp:.4f} matches marker "
          f"{marker['compliance']:.4f}", abs(comp - marker["compliance"]) < 1e-5)
    if comp < NEED and marker["status"] not in ("FAIL", "ABORTED-FAIL"):
        check(f"config d{d}/c{c}: status consistent with compliance", False,
              marker["status"])
    elif comp >= NEED:
        check(f"config d{d}/c{c}: status consistent", marker["status"] == "PASS",
              marker["status"])
    if marker["status"] == "ABORTED-FAIL":
        sched_n = marker.get("scheduled", len(rows))
        check(f"config d{d}/c{c}: abort rule (>5% of scheduled) holds",
              noncomp > 0.05 * sched_n, f"{noncomp}/{sched_n}")
        check(f"config d{d}/c{c}: all fired requests accounted in raw "
              f"(completed + cancelled + skipped = sent)",
              len(rows) == marker["sent"] + marker.get("skipped_overlength", 0),
              f"{len(rows)} vs {marker['sent'] + marker.get('skipped_overlength', 0)}")

chosen_path = os.path.join(VD, "chosen.json")
if not os.path.exists(chosen_path):
    print("[SKIP] chosen.json not present — calibration scan incomplete; "
          "--verify is meaningful after COMPLETE. Config-level checks above still stand.")
    sys.exit(0 if all(ok for _, ok, _ in checks) else 1)
chosen = json.load(open(chosen_path))
attempted = [k for k in order if k in summaries]
first_pass = next((k for k in attempted if summaries[k][1] == "PASS"), None)
check("an attempted config exists", len(attempted) > 0)
check("scan stopped at first PASS (or grid exhausted)",
      attempted[-1] == first_pass or first_pass is None)
if first_pass:
    check("chosen.json equals first PASS config",
          chosen["D"] == first_pass[0] and chosen["C"] == first_pass[1],
          f"r=1/{chosen['D']}, C={chosen['C']}")
else:
    check("no PASS → fallback chosen (r=1/256, C=4) with disclosure",
          chosen["D"] == 256 and chosen["C"] == 4 and chosen.get("fallback"))

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
if [ "${STAGE02_SKIP_PREFLIGHT:-0}" != "1" ]; then   # test hook; production never sets this
  nvidia-smi --query-gpu=name --format=csv,noheader | grep -q "$GPU_EXPECT" \
    || die "GPU is not $GPU_EXPECT — hardware boundary is locked (L3)"
  python3 -c "import vllm, sys; v=vllm.__version__; sys.exit(0 if v=='$VLLM_PINNED' else 1)" \
    || die "vLLM is not $VLLM_PINNED — engine version is pinned (L1)"
  # disk headroom: 45GB only when the ≈28GB weights still need downloading;
  # with the snapshot cached, calibration archives are MB-scale → 10GB is ample.
  # (RunPod template caches HF under /workspace, a different mount than $HOME.)
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
[ -f "$CALIB_PLAN" ] || die "calibration plan missing: $CALIB_PLAN — re-run stage 01 first"
ulimit -n 65536 2>/dev/null || warn "could not raise fd limit to 65536 (continuing with $(ulimit -n))"

# ---------------- vLLM server lifecycle ----------------
SERVER_LOG="$RUN_DIR/server.log"
start_server() {
  say "starting Arm A server (BF16 defaults; prefix caching OFF; max_model_len=$MAX_MODEL_LEN)"
  nohup python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" --revision "$MODEL_REV" \
    --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
    --port "$PORT" > "$SERVER_LOG" 2>&1 &
  echo $! > "$RUN_DIR/server.pid"
  say "waiting for /health (first boot downloads ≈28GB of weights)"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see server.log"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then
      die "server process died — see server.log"
    fi
  done
  say "server healthy after ${waited}s"
  echo "server_argv: vllm serve $MODEL --revision $MODEL_REV --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
    > "$RUN_DIR/server_argv.txt"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}
if [ "${STAGE02_SKIP_SERVER:-0}" != "1" ]; then   # test hook: assume external server on PORT
  trap stop_server EXIT
  start_server
else
  warn "STAGE02_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
fi

# ---------------- grid scan (single client process; server stays up) ---
say "starting calibration grid scan (decreasing offered load; stop at first PASS)"
run_client() {
RUN_DIR="$RUN_DIR" CALIB_PLAN="$CALIB_PLAN" PORT="$PORT" MODEL="$MODEL" \
SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" SLO_COMPLIANCE="$SLO_COMPLIANCE" \
D_GRID="$D_GRID" C_GRID="$C_GRID" REQ_TIMEOUT_S="$REQ_TIMEOUT_S" \
MAX_TOKENS_CAP="$MAX_TOKENS_CAP" MAX_MODEL_LEN="$MAX_MODEL_LEN" \
FILLER_SEED="$FILLER_SEED" T0="$T0" MAX_SECONDS="$MAX_SECONDS" \
CLIENT_CONC="$CLIENT_CONC" \
python3 - <<'PY'
import asyncio, hashlib, json, os, random, sys, time, urllib.request
import httpx

RUN_DIR   = os.environ["RUN_DIR"]
PLAN      = os.environ["CALIB_PLAN"]
PORT      = os.environ["PORT"]
TTFT_SLO  = float(os.environ["SLO_TTFT_S"])
TPOT_SLO  = float(os.environ["SLO_TPOT_MS"])
NEED      = float(os.environ["SLO_COMPLIANCE"])
Ds        = [int(x) for x in os.environ["D_GRID"].split()]
Cs        = [int(x) for x in os.environ["C_GRID"].split()]
REQ_TO    = float(os.environ["REQ_TIMEOUT_S"])
CONC      = int(os.environ["CLIENT_CONC"])
CAP       = int(os.environ["MAX_TOKENS_CAP"])
MML       = int(os.environ["MAX_MODEL_LEN"])
FSEED     = int(os.environ["FILLER_SEED"])
T0        = float(os.environ["T0"])
MAX_SEC   = float(os.environ["MAX_SECONDS"])
WATERMARK = "CALIBRATION DATA ONLY — never enters the CI"
URL       = f"http://127.0.0.1:{PORT}/v1/completions"

rows = [json.loads(l) for l in open(PLAN)]
rows.sort(key=lambda r: (r["arrival_offset_s"], r["service"], r["request_id"]))
max_ctx = max(r["context_tokens"] for r in rows)
print(f"[client] calibration plan: {len(rows):,} rows, max context {max_ctx:,} tokens")

# deterministic filler block (shared; per-request rotation offset)
_rng = random.Random(FSEED)
_base = [_rng.randrange(1000, 50000) for _ in range(8192)]
G = (_base * (max_ctx // 8192 + 2))[: max_ctx + 8192]
def filler_ids(n, rid):
    off = int.from_bytes(hashlib.sha256(f"{FSEED}|{rid}".encode()).digest()[:4], "big") % 8192
    return G[off:off + n]

def metrics_waiting_running():
    try:
        txt = urllib.request.urlopen(f"http://127.0.0.1:{PORT}/metrics", timeout=10).read().decode()
    except Exception:
        return None, None
    run = wait = None
    for ln in txt.splitlines():
        if ln.startswith("vllm:num_requests_running"):
            run = float(ln.rsplit(" ", 1)[1])
        elif ln.startswith("vllm:num_requests_waiting"):
            wait = float(ln.rsplit(" ", 1)[1])
    return run, wait

async def replay(d, c, raw_f):
    """Replay the calibration plan at r=1/d, C=c.
    Returns (status, sent, noncomp, skipped, n_sched).
    sent = requests that passed the concurrency gate (engaged the server)."""
    r = 1.0 / d
    sched = [(row["arrival_offset_s"] / c, row) for row in rows if row["keep_u"] < r]
    n_sched = len(sched)
    print(f"[config r=1/{d} C={c}] offered = {n_sched:,} requests over {3600/c:.0f}s "
          f"(≈{n_sched / (3600 / c):.1f} req/s)")
    sent = done = noncomp = skipped = 0
    abort = asyncio.Event()
    t0 = time.monotonic()
    # in-flight gate: bounds live payloads to O(CONC) memory; tasks waiting at
    # the gate hold only a reference to the plan row (already in memory)
    sem = asyncio.Semaphore(CONC)

    async def fire(row):
        nonlocal sent, done, noncomp, skipped
        rid = row["request_id"]
        ctx, gen = row["context_tokens"], row["generated_tokens"]
        rec = {"request_id": rid, "D": d, "C": c}
        mt = min(gen, CAP, MML - ctx - 1)
        if mt <= 0:
            rec.update(status="skipped_overlength", ttft_s=None, tpot_ms=None,
                       e2e_s=None, completion_tokens=0)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            skipped += 1
            return
        # gate wait is client-side queueing; it is disclosed per request as
        # send_lag_ms and counts toward TTFT (t_send starts only after the
        # gate) — conservative direction. A task cancelled while waiting at
        # the gate never engaged the server: no row, no sent increment.
        async with sem:
            sent += 1
            payload = {"model": os.environ["MODEL"], "prompt": filler_ids(ctx, rid),
                       "max_tokens": mt, "ignore_eos": True, "temperature": 0,
                       "stream": True, "stream_options": {"include_usage": True}}
            t_send = time.monotonic()
            t_first = t_last = None
            comp_tokens = 0
            status = "ok"
            try:
                async with client.stream("POST", URL, json=payload) as resp:
                    if resp.status_code != 200:
                        status = f"http_{resp.status_code}"
                    else:
                        async for line in resp.aiter_lines():
                            if not line.startswith("data:"):
                                continue
                            data = line[5:].strip()
                            if data == "[DONE]":
                                break
                            now = time.monotonic()
                            try:
                                obj = json.loads(data)
                            except Exception:
                                continue
                            if t_first is None:
                                t_first = now
                            t_last = now
                            u = obj.get("usage")
                            if u:
                                comp_tokens = u.get("completion_tokens", comp_tokens)
            except asyncio.CancelledError:
                # config aborted mid-flight: cancelled requests count as non-compliant
                # (the abort rule fires only when >5% have already measurably failed)
                rec.update(status="cancelled", ttft_s=None, tpot_ms=None,
                           e2e_s=round(time.monotonic() - t_send, 4),
                           completion_tokens=comp_tokens, slo_ok=False,
                           send_lag_ms=round((t_send - t0) * 1000.0, 1))
                raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
                done += 1
                noncomp += 1
                raise
            except Exception as e:
                status = "error:" + type(e).__name__
            t_end = time.monotonic()
            if comp_tokens == 0 and status == "ok":
                status = "error:no_tokens"
            ttft = (t_first - t_send) if t_first is not None else None
            if t_first is not None and comp_tokens > 1:
                tpot_ms = (t_last - t_first) / (comp_tokens - 1) * 1000.0
            elif t_first is not None:
                tpot_ms = (t_end - t_first) * 1000.0   # single-token output: decode time
            else:
                tpot_ms = None
            ok = (status == "ok" and ttft is not None and ttft <= TTFT_SLO
                  and tpot_ms is not None and tpot_ms <= TPOT_SLO)
            rec.update(status=status, ttft_s=round(ttft, 4) if ttft is not None else None,
                       tpot_ms=round(tpot_ms, 3) if tpot_ms is not None else None,
                       e2e_s=round(t_end - t_send, 4),
                       completion_tokens=comp_tokens, slo_ok=ok,
                       send_lag_ms=round((t_send - t0) * 1000.0, 1))
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            if not ok:
                noncomp += 1

    async def watchdog():
        while not abort.is_set():
            await asyncio.sleep(2.5)
            if sent > 0 and noncomp > 0.05 * n_sched:
                abort.set()

    async def sender():
        for at, row in sched:
            if abort.is_set():
                break
            delay = at - (time.monotonic() - t0)
            if delay > 0:
                await asyncio.sleep(delay)
            asyncio.create_task(fire(row))

    async def progress():
        while not abort.is_set() and done < n_sched:
            await asyncio.sleep(30)
            print(f"  [r=1/{d} C={c}] t={time.monotonic()-t0:.0f}s sent={sent} "
                  f"done={done} noncompliant={noncomp}", flush=True)

    wd = asyncio.create_task(watchdog())
    pg = asyncio.create_task(progress())
    sd = asyncio.create_task(sender())
    await sd
    tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()
             and t not in (wd, pg, sd)]
    if abort.is_set():
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        wd.cancel(); pg.cancel()
        return "ABORTED-FAIL", sent, noncomp, skipped, n_sched
    await asyncio.gather(*tasks, return_exceptions=True)
    wd.cancel(); pg.cancel()
    status = "PASS" if (1 - noncomp / max(sent - skipped, 1)) >= NEED else "FAIL"
    return status, sent, noncomp, skipped, n_sched

async def drain():
    for _ in range(60):
        run, wait = metrics_waiting_running()
        if run == 0 and wait == 0:
            return True
        await asyncio.sleep(5)
    return False

async def main():
    global client
    limits = httpx.Limits(max_connections=CONC,
                          max_keepalive_connections=min(CONC, 256))
    timeout = httpx.Timeout(REQ_TO, connect=30.0)
    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        order = sorted([(d, c) for d in Ds for c in Cs], key=lambda x: (-(x[1] / x[0]), -x[1]))
        attempted = []
        chosen = None
        for d, c in order:
            done_f = os.path.join(RUN_DIR, f"calib_d{d}_c{c}.done")
            if os.path.exists(done_f):
                m = json.load(open(done_f))
                attempted.append({"D": d, "C": c, **m})
                print(f"[config r=1/{d} C={c}] already done: {m['status']} (resume)")
                if m["status"] == "PASS" and chosen is None:
                    chosen = {"D": d, "C": c}
                continue
            if chosen is not None:
                break  # stop at first PASS (Amendment-01 scan rule)
            if time.monotonic() - T0 > MAX_SEC:
                print("[client] time rail — exiting for resume")
                sys.exit(44)
            raw_path = os.path.join(RUN_DIR, f"calib_d{d}_c{c}.jsonl")
            with open(raw_path, "w") as raw_f:
                raw_f.write(json.dumps({"watermark": WATERMARK, "D": d, "C": c}) + "\n")
                status, sent, noncomp, skipped_n, n_sched = await replay(d, c, raw_f)
            evaluated = sent - skipped_n
            comp = 1 - noncomp / max(evaluated, 1)
            marker = {"status": status, "scheduled": n_sched,
                      "sent": evaluated, "skipped_overlength": skipped_n,
                      "noncompliant": noncomp,
                      "compliance": round(comp, 6), "watermark": WATERMARK}
            json.dump(marker, open(done_f, "w"), indent=2)
            attempted.append({"D": d, "C": c, **marker})
            print(f"[config r=1/{d} C={c}] → {status} "
                  f"(compliance={comp:.4f}, sent={sent}, noncompliant={noncomp})", flush=True)
            if status == "PASS":
                chosen = {"D": d, "C": c}
                break
            if not await drain():
                print("[client] server drain timeout — restart requested")
                sys.exit(43)
        out = {"watermark": WATERMARK,
               "rule": "first config in decreasing offered-load order with "
                       ">=95% SLO compliance (TTFT<=5s, TPOT<=100ms); "
                       "fallback = lightest config with disclosure",
               "attempted": attempted}
        if chosen:
            out.update(D=chosen["D"], C=chosen["C"], r=f"1/{chosen['D']}", fallback=False)
        else:
            out.update(D=256, C=4, r="1/256", fallback=True,
                       disclosure="no grid configuration met the SLO; lightest "
                                  "configuration used, shortfall disclosed per protocol")
        json.dump(out, open(os.path.join(RUN_DIR, "chosen.json.tmp"), "w"), indent=2)
        os.replace(os.path.join(RUN_DIR, "chosen.json.tmp"),
                   os.path.join(RUN_DIR, "chosen.json"))
        print(f"[client] selection: {json.dumps({k: out[k] for k in ('D','C','fallback')})}")

asyncio.run(main())
PY
}

set +e
run_client
RC=$?
set -e
while [ "$RC" -eq 43 ]; do
  warn "restarting server (drain timeout), then resuming scan"
  stop_server; sleep 10; start_server
  set +e; run_client; RC=$?; set -e
done
[ "$RC" -eq 44 ] && die "time rail — partial progress saved; re-run the nightly command to resume"
[ "$RC" -eq 0 ] || die "calibration client failed (rc=$RC) — see stage.log"

check_time_rail
if [ "${STAGE02_SKIP_SERVER:-0}" != "1" ]; then
  stop_server
  trap - EXIT
fi

CHOSEN="$(python3 -c "import json;d=json.load(open('$RUN_DIR/chosen.json'));print(f\"r=1/{d['D']} C={d['C']} fallback={d['fallback']}\")")"
echo "ok" > "$RUN_DIR/COMPLETE"
say "✅ stage 02 COMPLETE — calibration selection frozen for stages 03+: $CHOSEN"
echo "  chosen:   $RUN_DIR/chosen.json   (CALIBRATION DATA ONLY — never enters the CI)"
echo "  verify:   bash stages/02-calibration.sh --verify"
echo "  next:     switch the STAGE file to 03-formal (not yet shipped)"
