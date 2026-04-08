#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

need_bin() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required binary: $1"
}

need_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required env var: ${name}"
}

aws_cli() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

kubectl_ctx() {
  kubectl "$@"
}

ensure_kubecontext() {
  log "Updating kubeconfig for cluster ${CLUSTER_NAME} (${AWS_REGION})"
  aws_cli eks update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null
}

json_get() {
  # Usage: json_get '<jq expr>' <<<"$json"
  jq -r "$1"
}

