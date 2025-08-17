#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# -------- Resolve Amplify App ID --------
if [[ -n "${APP_ID:-}" ]]; then
  AMPLIFY_APP_ID="$APP_ID"
else
  AMPLIFY_APP_ID="$(awk -F'"' '/AmplifyAppId/ {print $4; exit}' amplify/team-provider-info.json 2>/dev/null || true)"
fi
[[ -z "${AMPLIFY_APP_ID:-}" ]] && { log "ERROR: missing APP_ID / AmplifyAppId"; exit 1; }
log "Amplify AppId: $AMPLIFY_APP_ID"

# -------- Resolve backend env name --------
if [[ -n "${AMPLIFY_ENV:-}" ]]; then
  ENV_NAME="$AMPLIFY_ENV"
elif [[ -f amplify/team-provider-info.json ]]; then
  ENV_NAME="$(node -e "try{const t=require('./amplify/team-provider-info.json');console.log(Object.keys(t)[0]||'')}catch(e){process.exit(0)}" 2>/dev/null || true)"
  ENV_NAME="${ENV_NAME:-dev}"
else
  ENV_NAME="dev"
fi
log "Amplify env: $ENV_NAME"

# -------- Ensure full history if shallow --------
if git rev-parse --is-shallow-repository >/dev/null 2>&1 && git rev-parse --is-shallow-repository | grep -q true; then
  git fetch --unshallow --no-tags --prune origin "${AWS_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}" || true
fi

# -------- Determine commit range --------
CURR_COMMIT="${AWS_COMMIT_ID:-$(git rev-parse HEAD)}"
log "Current commit: $CURR_COMMIT"

PREV_DEPLOY_COMMIT="$(
  aws amplify list-jobs \
    --app-id "$AMPLIFY_APP_ID" \
    --branch-name "${AWS_BRANCH:-}" \
    --no-paginate \
    --query "reverse(sort_by(jobSummaries[?status=='SUCCEED' && commitId!='\`$CURR_COMMIT\`'], &startTime))[0].commitId" \
    --output text 2>/dev/null | tr -d '\r' | grep -E '^[0-9a-f]{7,}$' | head -n1
)"
[[ -z "$PREV_DEPLOY_COMMIT" || "$PREV_DEPLOY_COMMIT" == "None" ]] && PREV_DEPLOY_COMMIT="$(git rev-parse HEAD^ 2>/dev/null || git rev-list --max-parents=0 HEAD)"
log "Previous deployed commit: $PREV_DEPLOY_COMMIT"
git cat-file -e "$PREV_DEPLOY_COMMIT^{commit}" 2>/dev/null || git fetch origin "${AWS_BRANCH:-}" --deepen=1000 || true

# -------- Compute changed files --------
git diff --name-only "$PREV_DEPLOY_COMMIT" "$CURR_COMMIT" > /tmp/changed.txt || true
log "Changed files since last deployment:"; cat /tmp/changed.txt || true

# Nothing in backend? bail
grep -q '^amplify/backend/' /tmp/changed.txt || { log "No backend changes detected. Skipping."; exit 0; }

# Detect categories
FUNCTION_CHANGED=0; API_CHANGED=0
grep -q '^amplify/backend/function/' /tmp/changed.txt && FUNCTION_CHANGED=1
grep -Eq '^amplify/backend/api/|^graphql/|schema\.graphql$' /tmp/changed.txt && API_CHANGED=1

# Both → full helper path
if [[ "$FUNCTION_CHANGED" -eq 1 && "$API_CHANGED" -eq 1 ]]; then
  log "Functions AND API changed → amplifyPush --simple (pull + full push)"
  amplifyPush --simple
  exit 0
fi

# ---------- Minimal, SAFE pull (only if state files missing) ----------
NEED_PULL=0
[[ ! -f amplify/backend/amplify-meta.json ]] && NEED_PULL=1
[[ ! -f amplify/.config/local-env-info.json ]] && NEED_PULL=1

if [[ "$NEED_PULL" -eq 1 ]]; then
  # Backup changed function dirs before pull so they aren't overwritten
  mapfile -t FUNC_DIRS < <(grep -oE '^amplify/backend/function/[^/]+/' /tmp/changed.txt | sort -u)
  for d in "${FUNC_DIRS[@]:-}"; do
    [[ -d "$d" ]] || continue
    log "Backing up $d"
    tar -C "$d" -cf "/tmp/$(basename "$d").tar" .
  done

  log "Headless pull to hydrate local amplify/ state..."
  amplify pull --yes --appId "$AMPLIFY_APP_ID" --envName "$ENV_NAME"

  # Restore changed function folders over whatever the pull wrote
  for d in "${FUNC_DIRS[@]:-}"; do
    [[ -f "/tmp/$(basename "$d").tar" ]] || continue
    log "Restoring $d"
    mkdir -p "$d"
    tar -xf "/tmp/$(basename "$d").tar" -C "$d"
  done
else
  log "Local amplify state present; skipping pull."
fi

# ---------- Category-scoped push ----------
if [[ "$FUNCTION_CHANGED" -eq 1 ]]; then
  log "Only functions changed → amplify function push"
  amplify function push --yes
elif [[ "$API_CHANGED" -eq 1 ]]; then
  log "Only API changed → amplify api push"
  amplify api push --yes
else
  log "Other backend changes → full amplify push"
  amplify push --yes
fi
