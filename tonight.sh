#!/usr/bin/env bash
# ============================================================
# Effiq Pilot 002 — nightly entry point (public repo, no secrets)
# Flow: pull latest scripts → run the stage named in STAGE → push logs → done
# Bootstrap command (always the same):
#   bash <(curl -fsSL https://raw.githubusercontent.com/effiq/pilot002/main/tonight.sh)
# ============================================================
set -euo pipefail

SCRIPTS_REPO_URL="https://github.com/effiq/pilot002.git"
LOGS_REPO_HOST="github.com/effiq/pilot-logs.git"   # public log store; token joined at push time
EFFIQ_HOME="$HOME/effiq"
SCRIPTS_DIR="$EFFIQ_HOME/pilot002"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
TOKEN_FILE="$HOME/pilot-env/github-token"
DATE_STR="$(date -u +%Y-%m-%d)"

say() { printf '\n\033[1;36m[pilot] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[pilot][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 0. bootstrap: clone this repo on first run, then hand off ----
if [ ! -d "$SCRIPTS_DIR/.git" ]; then
  [ "${1:-}" = "--bootstrapped" ] && die "clone finished but repo not found — contact the maintainer"
  say "first run: cloning scripts repo"
  mkdir -p "$EFFIQ_HOME"
  git clone "$SCRIPTS_REPO_URL" "$SCRIPTS_DIR" || die "failed to clone scripts repo (check network)"
  exec bash "$SCRIPTS_DIR/tonight.sh" --bootstrapped
fi

# ---- 1. token check (token lives only on this pod, never in any repo) ----
[ -s "$TOKEN_FILE" ] || die "missing $TOKEN_FILE — pod-side token setup required (see internal ops guide)"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

# ---- 2. update scripts ----
say "updating scripts"
git -C "$SCRIPTS_DIR" pull --ff-only || die "failed to update scripts repo — contact the maintainer"

# ---- 3. prepare public log repo ----
# The token grants write access to the log repo only. Worst-case leak = junk commits
# to the log store; revoke and reissue to recover. The token file dies with the pod.
if [ ! -d "$LOGS_DIR/.git" ]; then
  say "first run: cloning log repo"
  git clone "https://x-access-token:${TOKEN}@${LOGS_REPO_HOST}" "$LOGS_DIR" \
    || die "failed to clone log repo (check token scope: Contents read/write on pilot-logs only)"
fi

# ---- 4. run current stage (stage is switched remotely via the STAGE file) ----
STAGE="$(tr -d '[:space:]' < "$SCRIPTS_DIR/STAGE")"
STAGE_SCRIPT="$SCRIPTS_DIR/stages/${STAGE}.sh"
[ -f "$STAGE_SCRIPT" ] || die "missing stage script: stages/${STAGE}.sh — contact the maintainer"

OUT_DIR="$LOGS_DIR/$DATE_STR/$STAGE"
mkdir -p "$OUT_DIR"
say "stage: ${STAGE} → logs: ${DATE_STR}/${STAGE}/"

set +e
bash "$STAGE_SCRIPT" 2>&1 | tee "$OUT_DIR/stage.log"
RC=${PIPESTATUS[0]}
set -e
echo "$RC" > "$OUT_DIR/exit-code.txt"

# ---- 5. safety check: refuse to push if the token leaked into logs ----
if grep -rqF "$TOKEN" "$LOGS_DIR" --exclude-dir=.git; then
  die "safety check tripped: token string found in logs; push aborted — contact the maintainer"
fi

# ---- 6. commit & push logs ----
say "pushing logs"
git -C "$LOGS_DIR" add -A
git -C "$LOGS_DIR" -c user.name="effiq-pilot" -c user.email="pilot@effiq.tech" \
  commit -m "${DATE_STR} ${STAGE} exit=${RC}" >/dev/null || true
git -C "$LOGS_DIR" push origin HEAD:main \
  || die "log push failed — contact the maintainer (on network errors simply re-run this script)"

# ---- 7. done ----
if [ "$RC" -eq 0 ]; then
  say "✅ stage ${STAGE} completed — safe to stop the pod."
else
  say "⚠️ stage ${STAGE} exited ${RC} — logs pushed; maintainer will pick it up. Safe to stop the pod."
fi
