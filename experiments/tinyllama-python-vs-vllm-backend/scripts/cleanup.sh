#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS_TINY="${NS_TINY:-tinyllama}"
NS_OBS="${NS_OBS:-observability}"

# Deletes K8s resources. PVC deletion is ON by default (to avoid EBS charges).
DELETE_PVCS="${DELETE_PVCS:-1}"

# Optionally delete AMG dashboards too.
DELETE_AMG_DASHBOARDS="${DELETE_AMG_DASHBOARDS:-0}"
AMG_WORKSPACE_ID="${AMG_WORKSPACE_ID:-g-e0027048fc}"
AMG_REGION="${AMG_REGION:-us-east-1}"
AMG_URL="${AMG_URL:-https://g-e0027048fc.grafana-workspace.us-east-1.amazonaws.com}"
AWS_PROFILE="${AWS_PROFILE:-adotobserve}"

echo "Deleting TinyLlama workloads..."
kubectl delete -f "$ROOT/deploy/triton-tinyllama.yaml" --ignore-not-found

if [ "$DELETE_PVCS" = "1" ]; then
  echo
  echo "Deleting PVCs (EBS volumes will be released per StorageClass reclaim policy)..."
  kubectl -n "$NS_TINY" delete pvc tinyllama-hf-cache tinyllama-hf-pydeps tinyllama-vllm-cache --ignore-not-found
else
  echo
  echo "Keeping PVCs (set DELETE_PVCS=1 to delete)."
fi

echo
echo "Deleting observability stack..."
kubectl delete -f "$ROOT/observability/prometheus.yaml" --ignore-not-found
kubectl delete -f "$ROOT/observability/jaeger.yaml" --ignore-not-found

if [ "$DELETE_AMG_DASHBOARDS" != "1" ]; then
  echo
  echo "Skipping AMG dashboard deletion (set DELETE_AMG_DASHBOARDS=1 to enable)."
  exit 0
fi

echo
echo "Deleting TinyLlama dashboards from AMG..."
KEY="$(aws --profile "$AWS_PROFILE" --region "$AMG_REGION" grafana create-workspace-api-key \
  --workspace-id "$AMG_WORKSPACE_ID" \
  --key-name "tinyllama-cleanup-$(date +%Y%m%d-%H%M%S)" \
  --key-role ADMIN \
  --seconds-to-live 600 \
  --query key --output text)"

uids=("tinyllama-hf" "tinyllama-vllm" "tinyllama-compare")
for uid in "${uids[@]}"; do
  curl -sS -H "Authorization: Bearer $KEY" -X DELETE "$AMG_URL/api/dashboards/uid/$uid" >/dev/null || true
done

echo "AMG dashboards deleted."

