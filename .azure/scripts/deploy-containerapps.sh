#!/usr/bin/env bash
# Canary deployment of one image to an Azure Container App, with automatic rollback.
#
# Strategy (the app runs in "multiple" revision mode; see .azure/infra/main.bicep):
#   1. Pin 100% of traffic to the current stable revision BY NAME, so a new revision gets 0%.
#   2. Create the new revision from the image digest (the exact bytes the build scanned),
#      with this environment's env vars / secrets.
#   3. Wait until it is provisioned, running and healthy.
#   4. Smoke test the new revision on its OWN revision FQDN: liveness, plus the build
#      version it reports. Real users still see 0% of it.
#   5. Canary: move CANARY_PERCENT of traffic to it for CANARY_SECONDS, probing the new
#      revision's health and checking the public URL isn't down (no answer / 5xx).
#   6. Promote to 100%. The previous revision stays active at 0% (instant rollback target);
#      older ones are deactivated.
#   Any failure after step 2: traffic back to the stable revision at 100%, the new revision
#   deactivated, exit 1.
#
# Runs inside AzureCLI@2 (already logged in via the workload-identity service connection).
#
# Inputs (environment variables):
#   APP_NAME, RESOURCE_GROUP, IMAGE (registry/repo@sha256:... or :tag), BUILD_NUMBER  required
#   HEALTH_PATH       liveness path (default /health)
#   VERSION_PATH      path returning JSON {"version": ...} that must equal BUILD_NUMBER (optional)
#   ENV_VARS_JSON     {"NAME":"value"}; a value of {{fqdn:<app>}} becomes https://<that app's FQDN>
#   SECRET_NAMES      comma-separated names of env vars holding secrets; each becomes a Container
#                     App secret plus an env var of the same name referencing it (secretref:)
#   CANARY_PERCENT    default 10; CANARY_SECONDS default 120
#   ATTEMPT           pipeline job attempt, keeps revision names unique on re-runs (default 1)
set -euo pipefail

: "${APP_NAME:?}" "${RESOURCE_GROUP:?}" "${IMAGE:?}" "${BUILD_NUMBER:?}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
VERSION_PATH="${VERSION_PATH:-}"
ENV_VARS_JSON="${ENV_VARS_JSON:-}"
[[ -z "$ENV_VARS_JSON" ]] && ENV_VARS_JSON='{}'
SECRET_NAMES="${SECRET_NAMES:-}"
CANARY_PERCENT="${CANARY_PERCENT:-10}"
CANARY_SECONDS="${CANARY_SECONDS:-120}"
ATTEMPT="${ATTEMPT:-1}"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "##vso[task.logissue type=error]$*"; exit 1; }
ca()   { az containerapp "$@" --name "$APP_NAME" --resource-group "$RESOURCE_GROUP" --only-show-errors; }

# probe URL [expected-version]  -> 0 when HTTP 200 (and version matches, if given)
probe() {
  local body
  body="$(curl -fsS --max-time 10 -H 'Cache-Control: no-cache' "$1")" || return 1
  [[ -z "${2:-}" ]] && return 0
  [[ "$(jq -r '.version // empty' <<<"$body" 2>/dev/null)" == "$2" ]]
}
# public_up URL -> 0 unless the endpoint is down (no answer or HTTP 5xx). During the canary the
# public URL is shared with the stable revision, which may predate /health (e.g. the Bicep
# placeholder on the first deployment), so only an outage counts there, not a 404.
public_up() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Cache-Control: no-cache' "$1" || true)"
  [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
}
probe_until() {  # url expected-version attempts
  local i
  for ((i = 1; i <= $3; i++)); do
    if probe "$1" "$2"; then log "healthy: $1"; return 0; fi
    log "not healthy yet ($i/$3): $1"; sleep 10
  done
  return 1
}

az extension add --name containerapp --upgrade --only-show-errors >/dev/null 2>&1 || true

# ── 0. Revision mode and current stable revision ───────────────────────────────
if [[ "$(ca show --query properties.configuration.activeRevisionsMode -o tsv)" != "Multiple" ]]; then
  log "Switching $APP_NAME to multiple revision mode (needed for traffic splitting)"
  ca revision set-mode --mode multiple >/dev/null
fi
STABLE="$(ca ingress traffic show --query "sort_by([?weight > \`0\` && revisionName != \`null\`], &weight)[-1].revisionName" -o tsv)"
[[ -z "$STABLE" ]] && STABLE="$(ca show --query properties.latestReadyRevisionName -o tsv)"
[[ -z "$STABLE" ]] && fail "Could not determine the current stable revision of $APP_NAME."
APP_FQDN="$(ca show --query properties.configuration.ingress.fqdn -o tsv)"
log "Stable revision: $STABLE  (https://$APP_FQDN)"

# ── 1. Pin traffic so the new revision starts at 0% ────────────────────────────
ca ingress traffic set --revision-weight "$STABLE=100" >/dev/null

# ── 2. Environment variables and secrets ───────────────────────────────────────
ENV_ARGS=()
while IFS=$'\t' read -r name value; do
  [[ -z "$name" ]] && continue
  if [[ "$value" =~ ^\{\{fqdn:([a-z0-9-]+)\}\}$ ]]; then
    peer="${BASH_REMATCH[1]}"
    peer_fqdn="$(az containerapp show -n "$peer" -g "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv --only-show-errors)"
    [[ -z "$peer_fqdn" ]] && fail "Container App '$peer' (referenced by $name) has no ingress FQDN."
    value="https://$peer_fqdn"
  fi
  ENV_ARGS+=("$name=$value")
done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' <<<"$ENV_VARS_JSON")

SECRET_ARGS=()
IFS=',' read -ra secret_names <<<"$SECRET_NAMES"
for name in "${secret_names[@]}"; do
  name="$(xargs <<<"$name")"; [[ -z "$name" ]] && continue
  value="${!name:-}"
  if [[ -z "$value" || "$value" == '$('* ]]; then
    echo "##vso[task.logissue type=warning]Secret '$name' is not set in the variable group; skipping it."
    continue
  fi
  secret_ref="$(tr '[:upper:]_' '[:lower:]-' <<<"$name" | tr -s '-')"   # ACA secret names: [a-z0-9-]
  SECRET_ARGS+=("$secret_ref=$value")
  ENV_ARGS+=("$name=secretref:$secret_ref")
done
if ((${#SECRET_ARGS[@]})); then
  log "Updating ${#SECRET_ARGS[@]} Container App secret(s)"
  ca secret set --secrets "${SECRET_ARGS[@]}" >/dev/null
fi

# ── 3. New revision ────────────────────────────────────────────────────────────
SUFFIX="b$(tr '.' '-' <<<"$BUILD_NUMBER")-a$ATTEMPT"
NEW="$APP_NAME--$SUFFIX"
log "Creating revision $NEW from $IMAGE"
UPDATE_ARGS=(--image "$IMAGE" --revision-suffix "$SUFFIX")
((${#ENV_ARGS[@]})) && UPDATE_ARGS+=(--set-env-vars "${ENV_ARGS[@]}")
ca update "${UPDATE_ARGS[@]}" >/dev/null

rollback() {
  echo "##vso[task.logissue type=error]Deployment of $NEW failed: rolling back to $STABLE"
  ca ingress traffic set --revision-weight "$STABLE=100" >/dev/null || true
  ca revision deactivate --revision "$NEW" >/dev/null || true
  log "Traffic restored to $STABLE; $NEW deactivated."
  exit 1
}
trap rollback ERR

for ((i = 1; i <= 40; i++)); do
  read -r prov health running < <(ca revision show --revision "$NEW" \
    --query "[properties.provisioningState, properties.healthState, properties.runningState]" -o tsv | tr '\n' ' '; echo)
  log "revision $NEW: provisioning=$prov health=$health running=$running"
  [[ "$prov" == "Failed" ]] && false
  [[ "$prov" == "Provisioned" && "$health" == "Healthy" ]] && break
  ((i == 40)) && false
  sleep 15
done

# ── 4. Smoke test the new revision directly (0% of users) ──────────────────────
REV_FQDN="$(ca revision show --revision "$NEW" --query properties.fqdn -o tsv)"
probe_until "https://$REV_FQDN$HEALTH_PATH" "" 12
[[ -n "$VERSION_PATH" ]] && probe_until "https://$REV_FQDN$VERSION_PATH" "$BUILD_NUMBER" 3

# ── 5. Canary ──────────────────────────────────────────────────────────────────
if ((CANARY_PERCENT > 0 && CANARY_PERCENT < 100)); then
  log "Canary: $NEW=$CANARY_PERCENT%, $STABLE=$((100 - CANARY_PERCENT))% for ${CANARY_SECONDS}s"
  ca ingress traffic set --revision-weight "$STABLE=$((100 - CANARY_PERCENT))" "$NEW=$CANARY_PERCENT" >/dev/null
  end=$((SECONDS + CANARY_SECONDS))
  while ((SECONDS < end)); do
    probe "https://$REV_FQDN$HEALTH_PATH" || { log "canary revision failed its probe"; false; }
    public_up "https://$APP_FQDN/" || { log "public endpoint is down (no answer or HTTP 5xx)"; false; }
    sleep 10
  done
fi

# ── 6. Promote ─────────────────────────────────────────────────────────────────
ca ingress traffic set --revision-weight "$NEW=100" "$STABLE=0" >/dev/null
trap - ERR
log "Promoted $NEW to 100%. $STABLE kept active at 0% as the rollback target."

for old in $(ca revision list --query "[?properties.active && name != '$NEW' && name != '$STABLE'].name" -o tsv); do
  log "Deactivating old revision $old"
  ca revision deactivate --revision "$old" >/dev/null || true
done

echo "##vso[task.setvariable variable=previousRevision;isOutput=true]$STABLE"
echo "##vso[task.setvariable variable=newRevision;isOutput=true]$NEW"
log "Done: https://$APP_FQDN serves build $BUILD_NUMBER ($NEW)."
