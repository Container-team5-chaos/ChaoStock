#!/usr/bin/env bash
set -euo pipefail
TEAM="${TEAM:-5}"
CONTEXT="${CONTEXT:-container-5}"
NS="container-${TEAM}"
if [[ "${CONTEXT}" != "${NS}" ]]; then
  printf 'ERROR: expected context %s, got %s\n' "${NS}" "${CONTEXT}" >&2
  exit 1
fi
for tool in kubectl helm docker; do
  command -v "$tool" >/dev/null || { echo "Missing executable: $tool" >&2; exit 1; }
done
printf 'EKS preflight (READ-ONLY), context=%s namespace=%s\n' "$CONTEXT" "$NS"
kubectl --context "$CONTEXT" -n "$NS" get resourcequota,limitrange
printf '\nCurrently deployed workloads and services:\n'
kubectl --context "$CONTEXT" -n "$NS" get deployments,statefulsets,services,ingresses,persistentvolumeclaims
printf '\nHelm releases in namespace:\n'
helm list --kube-context "$CONTEXT" -n "$NS"
printf '\nDB Secret (presence only; never print value):\n'
if ! kubectl --context "$CONTEXT" -n "$NS" get secret chaostock-db -o name; then
  echo 'Secret is missing. Create it once before EKS deploy; do not rotate it while PVC is initialized.' >&2
  exit 1
fi
printf '\nPreflight complete. Verify quotas have sufficient free space and no conflicting releases before proceeding.\n'
