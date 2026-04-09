#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NS_TINY="${NS_TINY:-tinyllama}"
NS_OBS="${NS_OBS:-observability}"

AMG_WORKSPACE_ID="${AMG_WORKSPACE_ID:-g-e0027048fc}"
AMG_REGION="${AMG_REGION:-us-east-1}"
AMG_URL="${AMG_URL:-https://g-e0027048fc.grafana-workspace.us-east-1.amazonaws.com}"
AWS_PROFILE="${AWS_PROFILE:-adotobserve}"
IMPORT_DASHBOARDS="${IMPORT_DASHBOARDS:-1}"

echo "Applying cluster manifests..."
kubectl apply -f "$ROOT/observability/jaeger.yaml"
kubectl apply -f "$ROOT/observability/prometheus.yaml"
kubectl apply -f "$ROOT/deploy/triton-tinyllama.yaml"

echo
echo "Waiting for rollouts..."
kubectl -n "$NS_OBS" rollout status deploy/jaeger --timeout=15m
kubectl -n "$NS_OBS" rollout status deploy/prometheus --timeout=15m
kubectl -n "$NS_TINY" rollout status deploy/tinyllama-triton-hf --timeout=30m
kubectl -n "$NS_TINY" rollout status deploy/tinyllama-triton-vllm --timeout=30m

echo
echo "Services:"
echo "- HF svc:   $(kubectl -n "$NS_TINY" get svc tinyllama-triton-hf-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo "- vLLM svc: $(kubectl -n "$NS_TINY" get svc tinyllama-triton-vllm-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo
echo "Port-forward helpers:"
echo "  kubectl -n $NS_TINY port-forward svc/tinyllama-triton-hf-svc 18002:8000"
echo "  kubectl -n $NS_TINY port-forward svc/tinyllama-triton-vllm-svc 18001:8000"

if [ "$IMPORT_DASHBOARDS" != "1" ]; then
  echo
  echo "Skipping AMG dashboard import (set IMPORT_DASHBOARDS=1 to enable)."
  exit 0
fi

echo
echo "Importing AMG dashboards (and deleting old TinyLlama dashboards)..."

KEY="$(aws --profile "$AWS_PROFILE" --region "$AMG_REGION" grafana create-workspace-api-key \
  --workspace-id "$AMG_WORKSPACE_ID" \
  --key-name "tinyllama-bootstrap-$(date +%Y%m%d-%H%M%S)" \
  --key-role ADMIN \
  --seconds-to-live 900 \
  --query key --output text)"

import_one() {
  local file="$1"
  local body
  body="$(python3 - <<PY
import json
d=json.load(open("$file","r"))
print(json.dumps({"dashboard": d, "folderId": 0, "overwrite": True}))
PY
)"
  curl -sS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -X POST "$AMG_URL/api/dashboards/db" \
    -d "$body" >/dev/null
}

SEARCH="$(curl -sS -H "Authorization: Bearer $KEY" "$AMG_URL/api/search?query=tinyllama&type=dash-db")"
EXTRA_UIDS="$(SEARCH="$SEARCH" ALLOW_UIDS="$(python3 -c 'import json; print(json.dumps(["tinyllama-hf","tinyllama-vllm","tinyllama-compare"]))')" python3 - <<'PY'
import json, os
search=json.loads(os.environ["SEARCH"])
allow=set(json.loads(os.environ["ALLOW_UIDS"]))
extra=[d["uid"] for d in search if d.get("uid") not in allow]
print("\n".join(extra))
PY
)"

if [ -n "$EXTRA_UIDS" ]; then
  while IFS= read -r uid; do
    [ -z "$uid" ] && continue
    curl -sS -H "Authorization: Bearer $KEY" -X DELETE "$AMG_URL/api/dashboards/uid/$uid" >/dev/null || true
  done <<<"$EXTRA_UIDS"
fi

import_one "$ROOT/observability/dashboards/tinyllama-hf.json"
import_one "$ROOT/observability/dashboards/tinyllama-vllm.json"
import_one "$ROOT/observability/dashboards/tinyllama-compare.json"

echo "AMG dashboards ready:"
echo "- $AMG_URL/d/tinyllama-hf"
echo "- $AMG_URL/d/tinyllama-vllm"
echo "- $AMG_URL/d/tinyllama-compare"

