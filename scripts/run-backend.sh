#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# -------- Resolve Amplify App ID --------
if [[ -n "${APP_ID:-}" ]]; then
  AMPLIFY_APP_ID="$APP_ID"
else
  # Try to read from team-provider-info.json (Gen 1 projects)
  AMPLIFY_APP_ID="$(awk -F'"' '/AmplifyAppId/ {print $4; exit}' amplify/team-provider-info.json 2>/dev/null || true)"
fi
if [[ -z "${AMPLIFY_APP_ID:-}" ]]; then
  log "ERROR: Amplify AppId not found. Set APP_ID env var or keep AmplifyAppId in amplify/team-provider-info.json"
  exit 1
fi
log "Amplify AppId: $AMPLIFY_APP_ID"

# -------- Resolve backend environment name --------
if [[ -n "${AMPLIFY_ENV:-}" ]]; then
  ENV_NAME="$AMPLIFY_ENV"
elif [[ -f amplify/team-provider-info.json ]]; then
  # Use Node to read first env key; fallback to 'dev'
  ENV_NAME="$(node -e "try{const t=require('./amplify/team-provider-info.json');console.log(Object.keys(t)[0]||'')}catch(e){process.exit(0)}" 2>/dev/null || true)"
  ENV_NAME="${ENV_NAME:-dev}"
else
  ENV_NAME="dev"
fi
log "Amplify env: $ENV_NAME"

# -------- Ensure full history if shallow clone --------
if git rev-parse --is-shallow-repository >/dev/null 2>&1 && git rev-parse --is-shallow-repository | grep -q true; then
  git fetch --unshallow --no-tags --prune origin "${AWS_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}" || true
fi

# -------- Determine commit range --------
CURR_COMMIT="${AWS_COMMIT_ID:-$(git rev-parse HEAD)}"
log "Current commit: $CURR_COMMIT"

# Find previous successful deploy commit for this branch
PREV_DEPLOY_COMMIT="$(
  aws amplify list-jobs \
    --app-id "$AMPLIFY_APP_ID" \
    --branch-name "${AWS_BRANCH:-}" \
    --no-paginate \
    --query "reverse(sort_by(jobSummaries[?status=='SUCCEED' && commitId!='\`$CURR_COMMIT\`'], &startTime))[0].commitId" \
    --output text 2>/dev/null \
  | tr -d '\r' \
  | grep -E '^[0-9a-f]{7,}$' \
  | head -n1
)"
if [[ -z "$PREV_DEPLOY_COMMIT" || "$PREV_DEPLOY_COMMIT" == "None" ]]; then
  PREV_DEPLOY_COMMIT="$(git rev-parse HEAD^ 2>/dev/null || git rev-list --max-parents=0 HEAD)"
fi
log "Previous deployed commit: $PREV_DEPLOY_COMMIT"

# Make sure we have that commit locally (shallow history safety)
git cat-file -e "$PREV_DEPLOY_COMMIT^{commit}" 2>/dev/null || \
  git fetch origin "${AWS_BRANCH:-}" --deepen=1000 || true

# -------- Compute changed files since previous deploy --------
git diff --name-only "$PREV_DEPLOY_COMMIT" "$CURR_COMMIT" > /tmp/changed.txt || true
log "Changed files since last deployment:"
cat /tmp/changed.txt || true

# If nothing in backend changed, bail out
if ! grep -q '^amplify/backend/' /tmp/changed.txt; then
  log "No backend changes detected. Skipping backend push."
  exit 0
fi

# -------- Detect categories changed --------
FUNCTION_CHANGED=0
API_CHANGED=0
grep -q '^amplify/backend/function/' /tmp/changed.txt && FUNCTION_CHANGED=1
grep -Eq '^amplify/backend/api/|^graphql/|schema\.graphql$' /tmp/changed.txt && API_CHANGED=1

# -------- Both changed → full helper path --------
if [[ "$FUNCTION_CHANGED" -eq 1 && "$API_CHANGED" -eq 1 ]]; then
  log "Functions AND API changed → amplifyPush --simple (pull + full push)"
  amplifyPush --simple
  exit 0
fi

# -------- Minimal headless pull to hydrate local state --------
log "Headless pull to hydrate local amplify/ state..."
# Do NOT pass --providers JSON; Console supplies creds/region via the build role
amplify pull --yes --appId "$AMPLIFY_APP_ID" --envName "$ENV_NAME"

# -------- Category-scoped push --------
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
