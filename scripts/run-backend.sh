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

# Bail if no backend changes
grep -q '^amplify/backend/' /tmp/changed.txt || { log "No backend changes detected. Skipping."; exit 0; }

# -------- Detect categories changed --------
FUNCTION_CHANGED=0
API_CHANGED=0
TRANSFORM_CHANGED=0

grep -q '^amplify/backend/function/' /tmp/changed.txt && FUNCTION_CHANGED=1
grep -q '^amplify/backend/api/' /tmp/changed.txt && API_CHANGED=1
grep -q '^amplify/backend/api/.*/transform\.conf\.json$' /tmp/changed.txt && { TRANSFORM_CHANGED=1; API_CHANGED=1; }

# If both changed, do a full push path now
if [[ "$FUNCTION_CHANGED" -eq 1 && "$API_CHANGED" -eq 1 ]]; then
  log "Functions AND API changed → amplify pull + full push"
  amplify pull --yes --appId "$AMPLIFY_APP_ID" --envName "$ENV_NAME"
  amplify push --yes
  exit 0
fi

# -------- Prepare arrays (avoid nounset issues) --------
declare -a FUNC_DIRS=()
declare -a SCHEMA_FILES_SINGLE=()
declare -a SCHEMA_FILES_SPLIT=()
declare -a SCHEMA_DIRS=()

# Gather changed function dirs and schema paths
mapfile -t FUNC_DIRS < <(grep -oE '^amplify/backend/function/[^/]+/' /tmp/changed.txt | sort -u || true)
mapfile -t SCHEMA_FILES_SINGLE < <(grep -oE '^amplify/backend/api/[^/]+/schema\.graphql$' /tmp/changed.txt | sort -u || true)
mapfile -t SCHEMA_FILES_SPLIT  < <(grep -oE '^amplify/backend/api/[^/]+/schema/.*\.graphql$' /tmp/changed.txt | sort -u || true)

# -------- Pull local state decision --------
NEED_PULL=0
[[ ! -f amplify/backend/amplify-meta.json ]] && NEED_PULL=1
[[ ! -f amplify/.config/local-env-info.json ]] && NEED_PULL=1

# Skip pull if local backend changes are present and local state exists
if [[ "$FUNCTION_CHANGED" -eq 1 || "$API_CHANGED" -eq 1 ]]; then
  if [[ "$NEED_PULL" -eq 1 ]]; then
    log "Local changes detected but local state missing; will PULL once, then restore/override."
  else
    NEED_PULL=0
    log "Local changes detected; skipping headless pull to avoid overwriting local backend state."
  fi
fi

backup_path() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  local key="/tmp/bak_$(echo "$p" | tr '/.' '__').tar"
  log "Backing up $p -> $key"
  tar -C "$(dirname "$p")" -cf "$key" "$(basename "$p")"
}
restore_path() {
  local p="$1"
  local key="/tmp/bak_$(echo "$p" | tr '/.' '__').tar"
  [[ -f "$key" ]] || return 0
  log "Restoring $p from $key"
  mkdir -p "$(dirname "$p")"
  tar -xf "$key" -C "$(dirname "$p")"
}

# Protect config & meta so pull can't drop your new resources.
CONFIG_FILES=(
  "amplify/backend/backend-config.json"
  "amplify/backend/amplify-meta.json"
)

# Build split-schema dir list only when needed
if (( ${#SCHEMA_FILES_SPLIT[@]} > 0 )); then
  mapfile -t SCHEMA_DIRS < <(
    printf '%s\n' "${SCHEMA_FILES_SPLIT[@]}" | sed -E 's#/schema/.*$#/schema/#' | sort -u
  )
fi

if [[ "$NEED_PULL" -eq 1 ]]; then
  # Back up changed function dirs, schema, and protected config/meta (if they exist)
  if (( ${#FUNC_DIRS[@]} > 0 )); then
    for d in "${FUNC_DIRS[@]}"; do backup_path "$d"; done
  fi
  if (( ${#SCHEMA_FILES_SINGLE[@]} > 0 )); then
    for f in "${SCHEMA_FILES_SINGLE[@]}"; do backup_path "$f"; done
  fi
  if (( ${#SCHEMA_DIRS[@]} > 0 )); then
    for d in "${SCHEMA_DIRS[@]}"; do backup_path "$d"; done
  fi
  for cf in "${CONFIG_FILES[@]}"; do backup_path "$cf"; done

  log "Headless pull to hydrate local amplify/ state..."
  amplify pull --yes --appId "$AMPLIFY_APP_ID" --envName "$ENV_NAME"

  # Restore protected content over whatever the pull wrote
  if (( ${#FUNC_DIRS[@]} > 0 )); then
    for d in "${FUNC_DIRS[@]}"; do restore_path "$d"; done
  fi
  if (( ${#SCHEMA_FILES_SINGLE[@]} > 0 )); then
    for f in "${SCHEMA_FILES_SINGLE[@]}"; do restore_path "$f"; done
  fi
  if (( ${#SCHEMA_DIRS[@]} > 0 )); then
    for d in "${SCHEMA_DIRS[@]}"; do restore_path "$d"; done
  fi
  for cf in "${CONFIG_FILES[@]}"; do restore_path "$cf"; done
else
  log "Local amplify state present; skipping pull."
fi

# -------- Sanity log & guard: registered functions vs folders --------
log "Functions registered in backend-config.json:"
node -e 'const fs=require("fs");const p="amplify/backend/backend-config.json";
try{const j=JSON.parse(fs.readFileSync(p,"utf8"));console.log(Object.keys(j.function||{}).join(", ")||"(none)");}catch(e){console.log("(none)");}' || true

# Fail fast if a function dir exists but is NOT registered (prevents confusing "No changes detected")
mapfile -t FUNC_DIRS_ON_DISK < <(ls -1 amplify/backend/function 2>/dev/null | sort -u || true)
mapfile -t FUNC_KEYS_IN_CONFIG < <(node -e 'const fs=require("fs");const p="amplify/backend/backend-config.json";
try{const j=JSON.parse(fs.readFileSync(p,"utf8"));console.log(Object.keys(j.function||{}).join("\n"));}catch(e){}' | sort -u || true)

if (( ${#FUNC_DIRS_ON_DISK[@]} > 0 )); then
  UNREGISTERED=$(
    comm -23 \
      <(printf "%s\n" "${FUNC_DIRS_ON_DISK[@]}" | sort) \
      <(printf "%s\n" "${FUNC_KEYS_IN_CONFIG[@]}" | sort) || true
  )
  if [[ -n "${UNREGISTERED:-}" ]]; then
    log "ERROR: Found function directory/ies not registered in backend-config.json:"
    printf '%s\n' "$UNREGISTERED"
    log "Run 'amplify add function' (or commit backend-config.json) to register them."
    exit 1
  fi
fi

# -------- Authoritative check via Amplify status (ANSI-safe) --------
STATUS_JSON="$(mktemp)"

# Try to suppress colors at the source; then strip any stray ANSI + CRs
export NO_COLOR=1
export FORCE_COLOR=0
amplify status --json \
  | sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g' \
  | tr -d '\r' \
  > "$STATUS_JSON"

# Optional: quick JSON validation (non-fatal)
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$STATUS_JSON" >/dev/null 2>&1 || {
  log "WARNING: amplify status JSON looked odd even after ANSI strip; continuing with best effort."
}

# Which functions does status think need action?
mapfile -t STATUS_FUNCTIONS < <(node -e 'const s=require(process.argv[1]);
const a=[...(s.resourcesToBeCreated||[]),...(s.resourcesToBeUpdated||[])];
console.log(a.filter(r=>r.category==="function").map(r=>r.resourceName).join("\n"))' "$STATUS_JSON" | sort -u || true)

# Which functions exist in backend-config?
mapfile -t CONFIG_FUNCTIONS < <(node -e 'const fs=require("fs");const p="amplify/backend/backend-config.json";
const j=JSON.parse(fs.readFileSync(p,"utf8"));console.log(Object.keys(j.function||{}).join("\n"))' | sort -u || true)

log "Functions needing action per 'amplify status': ${STATUS_FUNCTIONS[*]:-(none)}"

# Detect any functions present in backend-config but NOT in status create/update set
MISSING_IN_STATUS=$(
  comm -23 \
    <(printf "%s\n" "${CONFIG_FUNCTIONS[@]}" | sort) \
    <(printf "%s\n" "${STATUS_FUNCTIONS[@]}" | sort) || true
)

# -------- Category-scoped push with safe fallback --------
if [[ "$FUNCTION_CHANGED" -eq 1 ]]; then
  # if [[ -n "${MISSING_IN_STATUS:-}" ]]; then
  #   log "Status did not include some backend-config functions (${MISSING_IN_STATUS//$'\n'/, }); falling back to FULL push to force provisioning."
  #   amplify push --yes
  # else
  #   log "Only functions changed → amplify function push"
  log "Only functions changed → amplify function push"
  amplify function push --yes
  # amplify push function testFunctionNew2 --yes

elif [[ "$API_CHANGED" -eq 1 ]]; then
  if [[ "$TRANSFORM_CHANGED" -eq 1 ]]; then
    log "transform.conf.json changed → compiling & pushing GraphQL API"
  else
    log "API changed → compiling before API push"
  fi
  amplify api gql-compile
  amplify api push --yes

else
  log "Other backend changes → full amplify push"
  amplify push --yes
fi