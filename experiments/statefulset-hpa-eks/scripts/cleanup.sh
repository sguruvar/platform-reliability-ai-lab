#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

need_env AWS_PROFILE
need_env AWS_REGION
need_env CLUSTER_NAME

need_bin aws
need_bin kubectl
need_bin helm
need_bin eksctl
need_bin jq

DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-stateful-hpa}"
MON_NAMESPACE="${MON_NAMESPACE:-monitoring}"

KARPENTER_VERSION="${KARPENTER_VERSION:-1.10.0}"
AMP_ALIAS="${AMP_ALIAS:-${CLUSTER_NAME}-amp}"
AMG_NAME="${AMG_NAME:-${CLUSTER_NAME}-amg}"
KARPENTER_STACK_NAME="${KARPENTER_STACK_NAME:-Karpenter-${CLUSTER_NAME}}"

# Set to 1 to delete AWS-side resources (AMP/AMG/IAM policies and Karpenter CFN).
FULL_TEARDOWN="${FULL_TEARDOWN:-0}"

log "Cleanup for cluster: ${CLUSTER_NAME} (${AWS_REGION})"
ensure_kubecontext

delete_if_exists() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  kubectl_ctx -n "${ns}" get "${kind}" "${name}" >/dev/null 2>&1 || return 0
  kubectl_ctx -n "${ns}" delete "${kind}" "${name}" --wait=false >/dev/null || true
}

delete_ns_if_exists() {
  local ns="$1"
  kubectl_ctx get ns "${ns}" >/dev/null 2>&1 || return 0
  kubectl_ctx delete ns "${ns}" --wait=false >/dev/null || true
}

cleanup_demo() {
  log "Deleting demo namespace: ${DEMO_NAMESPACE}"
  delete_ns_if_exists "${DEMO_NAMESPACE}"
}

cleanup_monitoring() {
  log "Uninstalling kube-prometheus-stack (if present)"
  helm -n "${MON_NAMESPACE}" status kps >/dev/null 2>&1 && helm -n "${MON_NAMESPACE}" uninstall kps >/dev/null || true
  delete_ns_if_exists "${MON_NAMESPACE}"

  log "Deleting IRSA serviceaccount for Prometheus (if created via eksctl)"
  eksctl delete iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --namespace "${MON_NAMESPACE}" \
    --name prometheus-amp >/dev/null 2>&1 || true
}

cleanup_karpenter() {
  log "Removing Karpenter NodePool/NodeClass and Helm release"
  kubectl_ctx get nodepool default >/dev/null 2>&1 && kubectl_ctx delete nodepool default --wait=false >/dev/null || true
  kubectl_ctx get ec2nodeclass default >/dev/null 2>&1 && kubectl_ctx delete ec2nodeclass default --wait=false >/dev/null || true

  helm -n karpenter status karpenter >/dev/null 2>&1 && helm -n karpenter uninstall karpenter >/dev/null || true

  log "Deleting IRSA serviceaccount for Karpenter (if created via eksctl)"
  eksctl delete iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --namespace karpenter \
    --name karpenter >/dev/null 2>&1 || true

  delete_ns_if_exists karpenter
}

cleanup_aws_side() {
  [[ "${FULL_TEARDOWN}" == "1" ]] || return 0
  log "FULL_TEARDOWN=1: deleting AWS-side resources created by bootstrap"

  # AMP workspace
  local amp_ws_id
  amp_ws_id="$(
    aws_cli amp list-workspaces \
      | jq -r --arg a "${AMP_ALIAS}" '.workspaces[] | select(.alias==$a) | .workspaceId' \
      | head -n 1
  )"
  if [[ -n "${amp_ws_id}" && "${amp_ws_id}" != "null" ]]; then
    aws_cli amp delete-workspace --workspace-id "${amp_ws_id}" >/dev/null || true
  fi

  # AMG workspace
  local amg_ws_id
  amg_ws_id="$(
    aws_cli grafana list-workspaces \
      | jq -r --arg n "${AMG_NAME}" '.workspaces[] | select(.name==$n) | .id' \
      | head -n 1
  )"
  if [[ -n "${amg_ws_id}" && "${amg_ws_id}" != "null" ]]; then
    aws_cli grafana delete-workspace --workspace-id "${amg_ws_id}" >/dev/null || true
  fi

  # Karpenter CloudFormation stack
  aws_cli cloudformation describe-stacks --stack-name "${KARPENTER_STACK_NAME}" >/dev/null 2>&1 \
    && aws_cli cloudformation delete-stack --stack-name "${KARPENTER_STACK_NAME}" >/dev/null || true

  log "Note: IAM policies created by bootstrap are left in place by default."
  log "If you want them deleted too, tell me and I’ll add exact deletions (policies may have multiple versions/attachments)."
}

main() {
  cleanup_demo
  cleanup_monitoring
  cleanup_karpenter
  cleanup_aws_side
  log "Cleanup initiated (namespace deletions may take a bit to finalize)."
}

main "$@"

