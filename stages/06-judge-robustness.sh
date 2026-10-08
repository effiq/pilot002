#!/usr/bin/env bash
# =============================================================================
# Pilot 002 — Addendum-01: JUDGE-ROBUSTNESS PROBE (stage 06)
#
# Question (pre-registered in PREREG-ADDENDUM-01-judge-robustness.md, frozen
# before execution): stage 05's quality gate returned FAIL on the clarity axis
# (delta = -0.127 vs tolerance 0.1) with a single judge. Does that breach
# replicate across an independent judge panel scoring the SAME archived
# outputs, or is it consistent with single-judge noise?
#
# Scope discipline:
#   - This stage NEVER regenerates model outputs and NEVER touches GPU.
#   - It reads the sealed stage-05 archive (gen_A/gen_B/blind_map/frozen_set)
#     after verifying their sha256 against the constants below.
#   - Its verdict (verdict_jr.txt) is an ADDENDUM. It does not modify,
#     overturn, or re-open the sealed stage-05 verdict (verdict_q.txt).
#   - The blind map is REUSED from the stage-05 archive (hash-checked), so
#     every panel judge sees the identical presentation order the original
#     judge saw. No new randomness is introduced into item presentation.
#
# Judge policy (carried over, documented in stage 05 and Pilot 001):
#   - OpenAI / Anthropic / Google models are not reachable from this account's
#     billing region (OpenRouter policy).
#   - Qwen-family judges are excluded BY DESIGN (family conflict of interest:
#     the evaluated outputs come from Qwen2.5-14B-Instruct).
#   - The original judge (deepseek/deepseek-chat-v3-0324) is excluded from the
#     panel — it already produced the stage-05 verdict.
#   - Declared limitation: candidates #2/#3 share the DeepSeek family with the
#     original judge. The robustness question is about judge-instance
#     replication; observed same-family day-to-day drift (see VERDICT.md
#     post-hoc section) is itself larger than the breach margin, so family
#     overlap does not invalidate the probe. This is stated, not hidden.
#
# Panel rule (frozen): probe PANEL_CANDIDATES in order; the first
# PANEL_SIZE reachable models form the panel. Fewer than PANEL_SIZE reachable
# -> REFUSED (no partial panel; owner decision required).
#
# Panel outcome (frozen):
#   ROBUST-FAIL  : every panel judge breaches the clarity axis (delta < -TOL)
#   ROBUST-CLEAR : every panel judge is within tolerance on the clarity axis
#   MIXED        : otherwise
# All statistics are descriptive; the stage-05 verdict stands regardless.
#
# Usage:
#   bash stages/06-judge-robustness.sh            # run / resume
#   bash stages/06-judge-robustness.sh --verify <run_dir>   # recompute & compare
#
# Test hooks (env): STAGE06_SRC_DIR, STAGE06_OUT_DIR, OR_BASE_URL, KEY_FILE,
#   BUDGET_USD, MAX_SECONDS, PORT (unused), STAGE06_FORCE_VERIFY_ONLY
# =============================================================================
set -euo pipefail

# ---------- frozen constants (do not edit; edits require a new pre-registration) ----------
TOL=0.1
N_ITEMS=150
BOOT_SEED=20261012                                     # same declared seed as stage 05
BOOT_N=100000
PANEL_SIZE=2
BUDGET_USD="${BUDGET_USD:-5}"                          # judge spend cap (expected actual < $1)
MAX_SECONDS="${MAX_SECONDS:-7200}"
ORIG_JUDGE="deepseek/deepseek-chat-v3-0324"
ORIG_CLARITY_DELTA="-0.127"                            # sealed stage-05 clarity delta (verdict_q.txt)
# sha256 anchors of the sealed stage-05 archive (verified before any judging):
FROZEN_SHA=728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d
GENA_SHA=16df35ccad32cc60a5785ce87fa96e325487b66ec3000e3fa04e6479b886c8cd
GENB_SHA=8e79384a6c3a621d532dec4304da0c5a3fed960a256c606794e6135a0d9ba57c
BLIND_SHA=684aea8dcc33ce4f88d9aa8644007cdb8ace0e4ff331a124b8c62fe1c7e76392
PANEL_CANDIDATES=(
    "z-ai/glm-4.6|0.43|1.75"
    "deepseek/deepseek-v3.1-terminus|0.27|1.00"
    "deepseek/deepseek-chat-v3.1|0.25|0.95"
)
FALLBACK_PRICE_IN=1.00
FALLBACK_PRICE_OUT=3.00

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%F)"
KEY_FILE="${KEY_FILE:-$HOME/pilot-env/openrouter-key}"
OR_BASE_URL="${OR_BASE_URL:-https://openrouter.ai/api/v1}"
OR_BASE_URL="${OR_BASE_URL%/}"
START_TS="$(date +%s)"

note() { echo "[stage06] $*"; }
die()  { echo "[stage06][FATAL] $*" >&2; exit 1; }

GIT_REV="unknown"
if [ -d "$EFFIQ_HOME/pilot002/.git" ]; then
  GIT_REV=$(git -C "$EFFIQ_HOME/pilot002" rev-parse HEAD 2>/dev/null || echo unknown)
fi

# ---------- locate sealed stage-05 source archive ----------
find_src() {
  if [ -n "${STAGE06_SRC_DIR:-}" ]; then echo "$STAGE06_SRC_DIR"; return; fi
  local d latest=""
  for d in "$LOGS_DIR"/*/05-quality-gate/run_*; do
    [ -f "$d/COMPLETE" ] && latest="$d"
  done
  [ -n "$latest" ] && echo "$latest" || return 1
}

check_src() {
  SRC_DIR="$1"
  [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || die "sealed stage-05 archive not found (need a COMPLETE 05-quality-gate run under $LOGS_DIR)"
  python3 - "$SRC_DIR" "$FROZEN_SHA" "$GENA_SHA" "$GENB_SHA" "$BLIND_SHA" <<'PY' || die "stage-05 archive hash check FAILED — refusing to judge against unverified inputs"
import hashlib, os, sys
d = sys.argv[1]
expect = {"frozen_set.jsonl": sys.argv[2], "gen_A.jsonl": sys.argv[3],
          "gen_B.jsonl": sys.argv[4], "blind_map.jsonl": sys.argv[5]}
bad = []
for name, want in expect.items():
    p = os.path.join(d, name)
    got = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"
    if got != want: bad.append(f"{name}: got {got} want {want}")
if bad:
    print("anchor mismatch:"); [print("  " + b) for b in bad]; sys.exit(1)
print("stage-05 source archive anchors verified (frozen_set/gen_A/gen_B/blind_map)")
PY
  FROZEN_JSONL="$SRC_DIR/frozen_set.jsonl"
  GEN_A_JSONL="$SRC_DIR/gen_A.jsonl"
  GEN_B_JSONL="$SRC_DIR/gen_B.jsonl"
  BLIND_JSONL="$SRC_DIR/blind_map.jsonl"
  [ "$(wc -l < "$FROZEN_JSONL")" -eq "$N_ITEMS" ] || die "frozen set line count != $N_ITEMS"
  [ "$(wc -l < "$GEN_A_JSONL")" -ge "$N_ITEMS" ] || die "gen_A has fewer than $N_ITEMS rows"
  [ "$(wc -l < "$GEN_B_JSONL")" -ge "$N_ITEMS" ] || die "gen_B has fewer than $N_ITEMS rows"
  [ "$(wc -l < "$BLIND_JSONL")" -eq "$N_ITEMS" ] || die "blind map line count != $N_ITEMS"
}

set_paths() {
  RUN_DIR="$1"
  JUDGE_RAW_JSONL="$RUN_DIR/judge_raw_jr.jsonl"
  VERDICT_TXT="$RUN_DIR/verdict_jr.txt"
  VERDICT_JSON="$RUN_DIR/verdict_jr.json"
}

run_verdict() {
  RUN_DIR="$RUN_DIR" SRC_DIR="$SRC_DIR" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" \
  VERDICT_TXT="$VERDICT_TXT" VERDICT_JSON="$VERDICT_JSON" \
  N_ITEMS="$N_ITEMS" TOL="$TOL" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" \
  ORIG_JUDGE="$ORIG_JUDGE" ORIG_CLARITY_DELTA="$ORIG_CLARITY_DELTA" \
  GIT_REV="$GIT_REV" PANEL_SIZE="$PANEL_SIZE" python3 - <<'PY'
import hashlib, json, os, statistics

RUN_DIR = os.environ["RUN_DIR"]
SRC     = os.environ["SRC_DIR"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
VERDICTF= os.environ["VERDICT_TXT"]
VERDICTJ= os.environ["VERDICT_JSON"]
N_ITEMS = int(os.environ["N_ITEMS"])
TOL     = float(os.environ["TOL"])
BSEED   = int(os.environ["BOOT_SEED"])
BN      = int(os.environ["BOOT_N"])
PSIZE   = int(os.environ["PANEL_SIZE"])
AXES    = ["correctness", "instruction_following", "clarity"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"

lines = ["STAGE 06 VERDICT — JUDGE-ROBUSTNESS PROBE (PILOT 002 ADDENDUM-01)",
         "status: post-verdict addendum; does NOT modify the sealed stage-05 verdict (verdict_q.txt)",
         f"question: does the stage-05 clarity breach replicate across an independent judge panel",
         f"          scoring the SAME archived outputs? (tolerance={TOL}, same as stage 05)",
         "blind map reused from the stage-05 archive; identical presentation order for every judge",
         f"source archive: {SRC}",
         f"  frozen_set.jsonl: sha256={sha(os.path.join(SRC,'frozen_set.jsonl'))}",
         f"  gen_A.jsonl: sha256={sha(os.path.join(SRC,'gen_A.jsonl'))}",
         f"  gen_B.jsonl: sha256={sha(os.path.join(SRC,'gen_B.jsonl'))}",
         f"  blind_map.jsonl: sha256={sha(os.path.join(SRC,'blind_map.jsonl'))}",
         f"  judge_raw_jr.jsonl: sha256={sha(JRAW)}",
         f"scripts_rev={os.environ['GIT_REV']}",
         "",
         f"original judge (stage 05, sealed): {os.environ['ORIG_JUDGE']}  clarity delta {os.environ['ORIG_CLARITY_DELTA']} (breach)",
         ""]

rows = [json.loads(l) for l in open(JRAW) if l.strip()] if os.path.exists(JRAW) else []
judges = sorted({r["judge_model"] for r in rows}, key=lambda m: min(i for i, r in enumerate(rows) if r["judge_model"] == m))
lines.append(f"panel judges ({len(judges)}/{PSIZE}): {', '.join(judges) if judges else '(none)'}")

per_judge = {m: [r for r in rows if r["judge_model"] == m] for m in judges}
incomplete = [m for m in judges if len(per_judge[m]) < N_ITEMS]
total_expected = PSIZE * N_ITEMS
lines.append(f"judged rows: {len(rows)} / {total_expected}")

if len(judges) < PSIZE or incomplete or len(rows) < total_expected:
    lines += ["", f"REFUSED: probe incomplete — verdict sealed by pre-registration.",
              "Re-run the stage to resume; no panel outcome is computed on partial data."]
    open(VERDICTF, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

import numpy as np
report = {}
for m in judges:
    rs = per_judge[m]
    per_item = []
    for r in rs:
        sA = r["scores_r1"] if r["a_is_response_1"] else r["scores_r2"]
        sB = r["scores_r2"] if r["a_is_response_1"] else r["scores_r1"]
        per_item.append({a: (sA[a], sB[a]) for a in AXES})
    axis_delta = {a: statistics.mean(sc[a][1] for sc in per_item) - statistics.mean(sc[a][0] for sc in per_item) for a in AXES}
    item_delta = [statistics.mean(sc[a][1] - sc[a][0] for a in AXES) for sc in per_item]
    overall = statistics.mean(item_delta)
    gate_ok = overall >= -TOL and all(d >= -TOL for d in axis_delta.values())
    clarity_items = np.array([sc["clarity"][1] - sc["clarity"][0] for sc in per_item])
    rng = np.random.default_rng(BSEED)   # same seed for every judge (declared)
    means = rng.choice(clarity_items, size=(BN, len(clarity_items)), replace=True).mean(axis=1)
    lo, hi = np.percentile(means, [2.5, 97.5])
    report[m] = dict(axis_delta=axis_delta, overall=overall, gate_ok=gate_ok,
                     clarity_breach=axis_delta["clarity"] < -TOL, ci=(float(lo), float(hi)))
    mA = {a: statistics.mean(sc[a][0] for sc in per_item) for a in AXES}
    mB = {a: statistics.mean(sc[a][1] for sc in per_item) for a in AXES}
    lines += ["", f"[judge: {m}]"]
    for a in AXES:
        lines.append(f"  {a:22s}: A(bf16)={mA[a]:.3f}  B(fp8)={mB[a]:.3f}  delta={axis_delta[a]:+.3f}")
    lines.append(f"  overall pooled delta (B - A): {overall:+.3f}  ->  stage-05 criterion would give: {'PASS' if gate_ok else 'FAIL'}")
    lines.append(f"  clarity axis: {'BREACH' if report[m]['clarity_breach'] else 'within tolerance'} (delta {axis_delta['clarity']:+.3f} vs -{TOL})")
    lines.append(f"  [descriptive] 95% bootstrap CI of clarity delta: [{lo:+.3f}, {hi:+.3f}] (seed={BSEED}, resamples={BN})")

breaches = [report[m]["clarity_breach"] for m in judges]
if all(breaches): outcome = "ROBUST-FAIL"
elif not any(breaches): outcome = "ROBUST-CLEAR"
else: outcome = "MIXED"
expl = {"ROBUST-FAIL": "every panel judge replicates the clarity breach — the FAIL is judge-robust",
        "ROBUST-CLEAR": "no panel judge replicates the clarity breach — the FAIL is judge-fragile (consistent with single-judge noise)",
        "MIXED": "panel disagrees on the clarity axis — the breach is unresolved; treat as open"}[outcome]
lines += ["", f"panel rule: ROBUST-FAIL if all panel judges breach clarity; ROBUST-CLEAR if none do; else MIXED",
          "", f"PANEL OUTCOME: {outcome} — {expl}",
          "", "reminder: this addendum does not modify the sealed stage-05 verdict (FAIL).",
          "", "This file is reproducible from the archived logs alone: bash stages/06-judge-robustness.sh --verify <run_dir>"]
open(VERDICTF, "w").write("\n".join(lines) + "\n")
json.dump(dict(stage="06-judge-robustness", pilot="002-addendum-01",
               panel=judges, outcome=outcome,
               per_judge={m: dict(axis_delta=report[m]["axis_delta"], overall=report[m]["overall"],
                                  gate_ok=report[m]["gate_ok"], clarity_breach=report[m]["clarity_breach"],
                                  clarity_ci=list(report[m]["ci"])) for m in judges},
               scripts_rev=os.environ["GIT_REV"], source_archive=SRC),
          open(VERDICTJ, "w"), indent=2, sort_keys=True)
print("\n".join(lines))
PY
}

# ---------- --verify ----------
# Recompute the verdict from the archived logs and byte-compare. Declared
# normalization (verdict-invariant, machine-local provenance only):
#   - the "source archive:" path line
#   - scripts_rev=... (resolves only where a pilot002 git checkout exists)
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  [ -n "$D" ] && [ -f "$D/verdict_jr.txt" ] || { echo "VERIFY: usage: --verify <run_dir> (no verdict archive found)"; exit 1; }
  echo "=== verify: recomputing verdict from archived logs in $D (no network, no GPU) ==="
  SRC_DIR="$(find_src || true)"
  if [ -z "$SRC_DIR" ] && [ -f "$D/../05_src/frozen_set.jsonl" ]; then SRC_DIR="$D/../05_src"; fi
  [ -n "${SRC_DIR:-}" ] || { echo "VERIFY: stage-05 source archive not found on this machine"; exit 1; }
  check_src "$SRC_DIR"
  TMPD="$(mktemp -d)"
  cp "$D/judge_raw_jr.jsonl" "$TMPD/" 2>/dev/null || true
  set_paths "$TMPD"
  run_verdict > /dev/null
  python3 - "$D" "$TMPD" <<'PY'
import json, re, sys
a, b = sys.argv[1], sys.argv[2]
def norm_txt(t):
    t = re.sub(r"source archive: \S+", "source archive: NORMALIZED", t)
    t = re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
    return t
ta = norm_txt(open(a + "/verdict_jr.txt").read())
tb = norm_txt(open(b + "/verdict_jr.txt").read())
if ta != tb:
    import difflib
    print("\n".join(list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm=""))[:20]))
    print("VERIFY: MISMATCH — investigate before trusting the archive", file=sys.stderr); sys.exit(1)
ja = json.load(open(a + "/verdict_jr.json")); jb = json.load(open(b + "/verdict_jr.json"))
for j in (ja, jb): j.pop("scripts_rev", None); j.pop("source_archive", None)
if ja != jb:
    print("VERIFY: MISMATCH (json) — investigate", file=sys.stderr); sys.exit(1)
print("VERIFY: verdict_jr.txt / verdict_jr.json identical (declared provenance fields normalized)")
print("VERIFY: ALL CHECKS PASSED")
PY
  RC=$?
  rm -rf "$TMPD"
  exit $RC
fi

# ---------- run bookkeeping (resume-or-create; COMPLETE re-entry guard) ----------
if [ -n "${STAGE06_OUT_DIR:-}" ]; then
  OUT_BASE="$STAGE06_OUT_DIR"
else
  OUT_BASE="$LOGS_DIR/$DATE_STR/06-judge-robustness"
fi
mkdir -p "$OUT_BASE"
LATEST=""
for d in "$OUT_BASE"/run_*; do [ -d "$d" ] && LATEST="$d"; done
if [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
  note "run already COMPLETE: $LATEST"
  echo "verdict: $LATEST/verdict_jr.txt  (to recompute from logs: bash stages/06-judge-robustness.sh --verify $LATEST)"
  exit 0
fi
if [ -n "$LATEST" ]; then
  RUN_DIR="$LATEST"; note "resuming incomplete run: $RUN_DIR"
else
  RUN_DIR="$OUT_BASE/run_1"; mkdir -p "$RUN_DIR"; note "new run: $RUN_DIR"
fi
set_paths "$RUN_DIR"

if [ -n "${STAGE06_FORCE_VERIFY_ONLY:-}" ]; then note "verify-only flag set; exiting before judging"; exit 0; fi

# ---------- preflight ----------
SRC_DIR="$(find_src || true)"
check_src "$SRC_DIR"
note "stage-05 source: $SRC_DIR"
[ -f "$KEY_FILE" ] || die "judge key file missing: $KEY_FILE"
python3 -c "import numpy" 2>/dev/null || pip install -q numpy

# ---------- judging phase (byte-identical prompt/template to stage 05) ----------
note "blind judging with frozen panel (budget guard \$$BUDGET_USD, time guard ${MAX_SECONDS}s)"
SRC_DIR="$SRC_DIR" FROZEN_JSONL="$FROZEN_JSONL" GEN_A_JSONL="$GEN_A_JSONL" GEN_B_JSONL="$GEN_B_JSONL" \
BLIND_JSONL="$BLIND_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" \
KEY_FILE="$KEY_FILE" BUDGET_USD="$BUDGET_USD" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" \
OR_BASE_URL="$OR_BASE_URL" GIT_REV="$GIT_REV" N_ITEMS="$N_ITEMS" TOL="$TOL" PANEL_SIZE="$PANEL_SIZE" \
PANEL_CANDIDATES_STR="$(printf '%s\n' "${PANEL_CANDIDATES[@]}")" \
FALLBACK_PRICE_IN="$FALLBACK_PRICE_IN" FALLBACK_PRICE_OUT="$FALLBACK_PRICE_OUT" python3 - <<'PY'
import hashlib, json, os, time, datetime
import urllib.request, urllib.error

FROZEN  = os.environ["FROZEN_JSONL"]
GEN_A   = os.environ["GEN_A_JSONL"]
GEN_B   = os.environ["GEN_B_JSONL"]
BLINDF  = os.environ["BLIND_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
KEYF    = os.environ["KEY_FILE"]
BUDGET  = float(os.environ["BUDGET_USD"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])
ORBASE  = os.environ["OR_BASE_URL"]
N_ITEMS = int(os.environ["N_ITEMS"])
PSIZE   = int(os.environ["PANEL_SIZE"])
AXES    = ["correctness", "instruction_following", "clarity"]

CANDIDATES = []
for line in os.environ["PANEL_CANDIDATES_STR"].splitlines():
    if line.strip():
        m, ci, co = line.split("|")
        CANDIDATES.append((m, float(ci), float(co)))
FALLBACK_PRICE = (float(os.environ["FALLBACK_PRICE_IN"]), float(os.environ["FALLBACK_PRICE_OUT"]))

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
                 "X-Title": "effiq-pilot002-judge-robustness"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# ---- probe panel (frozen order; first PANEL_SIZE reachable form the panel) ----
panel, prices = [], {}
for cand, cin, cout in CANDIDATES:
    if len(panel) >= PSIZE: break
    try:
        resp = call_api(cand, [dict(role="user", content="Reply with the single word: ok")], max_tokens=4, timeout=60)
        _ = resp["choices"][0]["message"]["content"]
        panel.append(cand); prices[cand] = (cin, cout)
        print(f"panel judge {len(panel)}/{PSIZE}: {cand} (probe ok)")
    except Exception as e:
        print(f"panel candidate {cand}: unavailable ({type(e).__name__}: {e})")
if len(panel) < PSIZE:
    print(f"REFUSED: only {len(panel)}/{PSIZE} panel judges reachable — no partial panel (owner decision required).")
    raise SystemExit(1)

# ---- load sealed inputs ----
frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
def load_gen(p):
    return {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()}
gA, gB = load_gen(GEN_A), load_gen(GEN_B)
blind = {}
for l in open(BLINDF):
    if l.strip():
        r = json.loads(l); blind[r["request_id"]] = r["a_is_response_1"]

judged = {}
if os.path.exists(JRAW):
    for l in open(JRAW):
        if l.strip():
            r = json.loads(l); judged[(r["request_id"], r["judge_model"])] = r

def est_cost(model, ptoks, ctoks):
    cin, cout = prices.get(model, FALLBACK_PRICE)
    return (ptoks * cin + ctoks * cout) / 1e6

spent = sum(est_cost(r["judge_model"], r.get("prompt_tokens", 0), r.get("completion_tokens", 0))
            for r in judged.values())
print(f"judge resume: {len(judged)} rows already judged, est. spent so far ${spent:.3f} (budget guard ${BUDGET:.0f})")

# Byte-identical to the stage-05 judge prompt (see stages/05-quality-gate.sh).
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
    for jm in panel:
        for rec in frozen:
            rid = rec["request_id"]
            if (rid, jm) in judged or rid not in gA or rid not in gB:
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
                    resp = call_api(jm, msgs, max_tokens=300)
                    content = resp["choices"][0]["message"]["content"]
                    scores = parse_scores(content)
                    u = resp.get("usage", {})
                    row = dict(request_id=rid, judge_model=jm,
                               a_is_response_1=blind[rid],
                               scores_r1=scores["response_1"], scores_r2=scores["response_2"],
                               prompt_tokens=u.get("prompt_tokens", 0),
                               completion_tokens=u.get("completion_tokens", 0),
                               raw_content=content, scripts_rev=os.environ["GIT_REV"],
                               ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                    fj.write(json.dumps(row, sort_keys=True) + "\n"); fj.flush()
                    spent += est_cost(jm, row["prompt_tokens"], row["completion_tokens"])
                    n_new += 1; ok = True
                    if n_new % 20 == 0 or n_new == 1:
                        print(f"  judged {rid} by {jm} ({len(judged)+n_new}/{len(frozen)*len(panel)}), est. spent ${spent:.3f}")
                    break
                except Exception as e:
                    print(f"  judge error on {rid} by {jm} (attempt {attempt+1}): {type(e).__name__}: {e}")
                    time.sleep(pause)
            if not ok:
                n_fail += 1
                print(f"  {rid} by {jm}: all retries failed — left for next resume")

print(f"judge phase done: new={n_new} failed={n_fail} total_judged={len(judged)+n_new}/{len(frozen)*len(panel)} est_spent=${spent:.3f}")
PY

# ---------- verdict + completeness gate ----------
note "verdict (recomputed from archived logs)"
set +e
run_verdict
RC_V=$?
set -e

NJ=$(wc -l < "$JUDGE_RAW_JSONL" 2>/dev/null || echo 0)
NEXP=$(( N_ITEMS * PANEL_SIZE ))
if [ "$NJ" -ge "$NEXP" ] && [ "$RC_V" -eq 0 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  echo "STAGE 06 JUDGE-ROBUSTNESS PROBE: COMPLETE (rows=$NJ/$NEXP; see verdict_jr.txt)"
  exit 0
else
  echo "STAGE 06 JUDGE-ROBUSTNESS PROBE: INCOMPLETE (rows=$NJ/$NEXP; no COMPLETE marker — re-run the same command to resume)"
  exit 1
fi
