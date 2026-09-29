#!/usr/bin/env bash
# Registry retention for one repository, run by the pipeline right after each push.
#
# Why here and not as an ACR Task (`acr purge` on a schedule): ACR Tasks are blocked on
# free-trial and some sponsored subscriptions (TasksOperationsNotAllowed), and the retention
# *policy* feature needs the Premium tier. This works on any tier with plain `az acr` calls.
#
# Rule: keep the newest KEEP tagged images, plus ANY image an active Container App revision in
# the resource group runs (so a PROD that lags many builds behind can still scale out and roll
# back); delete everything else, untagged manifests included.
#
# Inputs (environment variables): ACR_NAME, REPOSITORY, RESOURCE_GROUP; KEEP (default 10);
# DRY_RUN=true lists without deleting.
# Needs the AcrDelete role on the registry (see .azure/SETUP.md, step 3).
set -euo pipefail

: "${ACR_NAME:?}" "${REPOSITORY:?}" "${RESOURCE_GROUP:?}"
KEEP="${KEEP:-10}"
DRY_RUN="${DRY_RUN:-false}"

# Digests in use by active revisions. Images are deployed as <registry>/<repo>@sha256:<digest>.
in_use="$(
  for app in $(az containerapp list -g "$RESOURCE_GROUP" --query "[].name" -o tsv --only-show-errors); do
    az containerapp revision list -n "$app" -g "$RESOURCE_GROUP" --only-show-errors \
      --query "[?properties.active].properties.template.containers[].image" -o tsv
  done | grep -o 'sha256:[0-9a-f]\{64\}' | sort -u || true
)"
echo "Digests in use by active Container App revisions: $(wc -w <<<"$in_use" | tr -d ' ')"

manifests="$(az acr manifest list-metadata --registry "$ACR_NAME" --name "$REPOSITORY" \
  --orderby time_desc --only-show-errors -o json)"

# Newest first: tagged ones beyond the first KEEP, then every untagged one.
candidates="$(jq -r --argjson keep "$KEEP" '
  ([.[] | select((.tags // []) | length > 0)] | .[$keep:] | .[].digest),
  ([.[] | select((.tags // []) | length == 0)] | .[].digest)
' <<<"$manifests")"

deleted=0; protected=0
for digest in $candidates; do
  if grep -qx "$digest" <<<"$in_use"; then
    echo "keep   $REPOSITORY@$digest (running in a Container App revision)"
    protected=$((protected + 1))
    continue
  fi
  echo "delete $REPOSITORY@$digest"
  if [[ "$DRY_RUN" != "true" ]]; then
    az acr repository delete --name "$ACR_NAME" --image "$REPOSITORY@$digest" --yes --only-show-errors >/dev/null
  fi
  deleted=$((deleted + 1))
done

total="$(jq length <<<"$manifests")"
echo "Retention for $REPOSITORY: $total manifest(s), keep newest $KEEP tagged; deleted $deleted, protected $protected (dry run: $DRY_RUN)."
