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
need_bin curl

KARPENTER_VERSION="${KARPENTER_VERSION:-1.10.0}"
AMP_ALIAS="${AMP_ALIAS:-${CLUSTER_NAME}-amp}"
AMG_NAME="${AMG_NAME:-${CLUSTER_NAME}-amg}"
AMG_AUTH_PROVIDER="${AMG_AUTH_PROVIDER:-AWS_SSO}"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-stateful-hpa}"
MON_NAMESPACE="${MON_NAMESPACE:-monitoring}"

KARPENTER_STACK_NAME="${KARPENTER_STACK_NAME:-Karpenter-${CLUSTER_NAME}}"

log "Target cluster: ${CLUSTER_NAME} (${AWS_REGION}) using profile ${AWS_PROFILE}"
ensure_kubecontext

ACCOUNT_ID="$(aws --profile "${AWS_PROFILE}" sts get-caller-identity | jq -r .Account)"
log "AWS account: ${ACCOUNT_ID}"

kubectl_ctx get nodes >/dev/null

ensure_policy_version_capacity() {
  # IAM managed policies allow max 5 versions. Delete the oldest non-default version if needed.
  local policy_arn="$1"
  local oldest_non_default
  oldest_non_default="$(
    aws --profile "${AWS_PROFILE}" iam list-policy-versions --policy-arn "${policy_arn}" \
      | jq -r '.Versions | map(select(.IsDefaultVersion==false)) | sort_by(.CreateDate) | .[0].VersionId // empty'
  )"
  if [[ -n "${oldest_non_default}" ]]; then
    aws --profile "${AWS_PROFILE}" iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${oldest_non_default}" >/dev/null
  fi
}

ensure_oidc_provider() {
  log "Ensuring EKS OIDC provider is associated (needed for IRSA)"
  eksctl utils associate-iam-oidc-provider \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --approve >/dev/null
}

install_metrics_server() {
  if kubectl_ctx -n kube-system get deploy metrics-server >/dev/null 2>&1; then
    log "Metrics Server already present; waiting for it to be ready"
    kubectl_ctx -n kube-system rollout status deploy/metrics-server --timeout=5m
    return 0
  fi

  log "Installing Metrics Server (for HPA CPU metrics)"
  kubectl_ctx apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml" >/dev/null
  kubectl_ctx -n kube-system rollout status deploy/metrics-server --timeout=5m
}

ensure_metrics_api_available() {
  # Some clusters end up with a metrics-server Service selector that doesn't match pod labels,
  # resulting in apiservice v1beta1.metrics.k8s.io = MissingEndpoints.
  local available
  available="$(kubectl_ctx get apiservice v1beta1.metrics.k8s.io -o json | jq -r '.status.conditions[]? | select(.type=="Available") | .status' 2>/dev/null || echo "")"
  if [[ "${available}" == "True" ]]; then
    return 0
  fi

  log "Metrics API not Available yet; attempting to fix MissingEndpoints"
  local ep_count
  ep_count="$(kubectl_ctx -n kube-system get endpoints metrics-server -o json 2>/dev/null | jq -r '(.subsets // []) | length' || echo "0")"
  if [[ "${ep_count}" == "0" ]]; then
    # Remove legacy selector key that may not exist on pods.
    kubectl_ctx -n kube-system patch svc metrics-server --type json -p '[{"op":"remove","path":"/spec/selector/k8s-app"}]' >/dev/null 2>&1 || true
  fi

  # Re-check
  available="$(kubectl_ctx get apiservice v1beta1.metrics.k8s.io -o json | jq -r '.status.conditions[]? | select(.type=="Available") | .status' 2>/dev/null || echo "")"
  [[ "${available}" == "True" ]] || die "Metrics API still not available; check metrics-server Service endpoints and apiservice status"
}

install_ebs_csi_addon() {
  log "Installing EBS CSI driver (EKS add-on) + IRSA"

  local role_name="AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}"
  local sa="ebs-csi-controller-sa"
  local ns="kube-system"

  # Important: with EKS managed add-ons, let the add-on own the ServiceAccount.
  # We only create the IAM role/trust (IRSA) and pass it to the add-on.
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --namespace "${ns}" \
    --name "${sa}" \
    --role-name "${role_name}" \
    --attach-policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
    --role-only \
    --approve >/dev/null

  local role_arn
  role_arn="$(aws --profile "${AWS_PROFILE}" iam get-role --role-name "${role_name}" | jq -r .Role.Arn)"

  local addon_status=""
  if aws_cli eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
    addon_status="$(aws_cli eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver | jq -r '.addon.status')"
  fi

  if [[ "${addon_status}" == "CREATE_FAILED" ]]; then
    # In case a conflicting ServiceAccount exists (e.g., created by a previous eksctl run), remove it before recreate.
    kubectl_ctx -n "${ns}" get sa "${sa}" >/dev/null 2>&1 && kubectl_ctx -n "${ns}" delete sa "${sa}" >/dev/null || true
    log "EBS CSI add-on is in CREATE_FAILED; deleting and recreating with conflict overwrite"
    aws_cli eks delete-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver >/dev/null || true
    aws_cli eks wait addon-deleted --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver
    addon_status=""
  fi

  if [[ -n "${addon_status}" ]]; then
    log "EBS CSI add-on already exists; updating to ensure IRSA role is attached (overwrite conflicts)"
    aws_cli eks update-addon \
      --cluster-name "${CLUSTER_NAME}" \
      --addon-name aws-ebs-csi-driver \
      --service-account-role-arn "${role_arn}" \
      --resolve-conflicts OVERWRITE >/dev/null
  else
    log "Creating EBS CSI add-on (overwrite conflicts)"
    aws_cli eks create-addon \
      --cluster-name "${CLUSTER_NAME}" \
      --addon-name aws-ebs-csi-driver \
      --service-account-role-arn "${role_arn}" \
      --resolve-conflicts OVERWRITE >/dev/null
  fi

  aws_cli eks wait addon-active --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver
  kubectl_ctx -n kube-system rollout status deploy/ebs-csi-controller --timeout=10m
}

apply_storageclass_gp3() {
  log "Applying StorageClass ebs-gp3"
  kubectl_ctx apply -f "${ROOT_DIR}/k8s/storageclass-ebs-gp3.yaml" >/dev/null
}

karpenter_download_cfn() {
  local out="$1"
  local base="https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}"
  local url1="${base}/website/content/en/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml"
  local url2="${base}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml"

  if curl -fsSL "${url1}" -o "${out}"; then
    return 0
  fi
  curl -fsSL "${url2}" -o "${out}"
}

install_karpenter() {
  log "Installing Karpenter v${KARPENTER_VERSION}"

  local cluster_json
  cluster_json="$(aws_cli eks describe-cluster --name "${CLUSTER_NAME}" --output json)"

  local subnets
  subnets="$(jq -r '.cluster.resourcesVpcConfig.subnetIds[]' <<<"${cluster_json}")"
  local sgs
  sgs="$(jq -r '.cluster.resourcesVpcConfig.securityGroupIds[]' <<<"${cluster_json}")"

  log "Tagging EKS subnets and security groups for Karpenter discovery"
  while read -r subnet_id; do
    aws_cli ec2 create-tags --resources "${subnet_id}" --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" >/dev/null
  done <<<"${subnets}"
  while read -r sg_id; do
    aws_cli ec2 create-tags --resources "${sg_id}" --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" >/dev/null
  done <<<"${sgs}"

  log "Deploying Karpenter CloudFormation stack: ${KARPENTER_STACK_NAME}"
  local cfn_file
  cfn_file="$(mktemp)"
  karpenter_download_cfn "${cfn_file}"

  aws_cli cloudformation deploy \
    --stack-name "${KARPENTER_STACK_NAME}" \
    --template-file "${cfn_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=${CLUSTER_NAME}" >/dev/null

  rm -f "${cfn_file}"

  local node_role="KarpenterNodeRole-${CLUSTER_NAME}"
  local node_role_arn
  node_role_arn="$(aws --profile "${AWS_PROFILE}" iam get-role --role-name "${node_role}" | jq -r .Role.Arn)"

  log "Ensuring Karpenter node role is mapped in aws-auth (so nodes can join)"
  eksctl create iamidentitymapping \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --arn "${node_role_arn}" \
    --username "system:node:{{EC2PrivateDNSName}}" \
    --group system:bootstrappers \
    --group system:nodes \
    --no-duplicate-arns >/dev/null 2>&1 || true

  # In Karpenter provider-aws v1.x, the Getting Started CloudFormation template creates the
  # interruption queue with QueueName == ClusterName (no Outputs section).
  local interruption_queue="${CLUSTER_NAME}"

  # The template creates multiple controller policies; attach all of them to the IRSA role.
  local policies_json
  policies_json="$(aws --profile "${AWS_PROFILE}" iam list-policies --scope Local)"

  policy_arn_for() {
    local pn="$1"
    jq -r --arg n "${pn}" '.Policies[] | select(.PolicyName==$n) | .Arn' <<<"${policies_json}" | head -n 1
  }

  local policy_names=(
    "KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}"
    "KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}"
    "KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}"
    "KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}"
    "KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}"
  )

  local attach_args=()
  local pn arn
  for pn in "${policy_names[@]}"; do
    arn="$(policy_arn_for "${pn}")"
    [[ -n "${arn}" && "${arn}" != "null" ]] || die "Could not find required Karpenter policy: ${pn}"
    attach_args+=(--attach-policy-arn "${arn}")
  done

  local controller_role_name="KarpenterControllerRole-${CLUSTER_NAME}"
  log "Creating/Updating IRSA for Karpenter controller: ${controller_role_name}"
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --namespace karpenter \
    --name karpenter \
    --role-name "${controller_role_name}" \
    "${attach_args[@]}" \
    --override-existing-serviceaccounts \
    --approve >/dev/null

  local controller_role_arn
  controller_role_arn="$(aws --profile "${AWS_PROFILE}" iam get-role --role-name "${controller_role_name}" | jq -r .Role.Arn)"

  log "Installing/Upgrading Karpenter Helm chart"
  local sa_mode_args=()
  if kubectl_ctx -n karpenter get sa karpenter >/dev/null 2>&1; then
    # SA is created/owned by eksctl (IRSA); tell Helm to reuse it.
    sa_mode_args+=(--set "serviceAccount.create=false")
    sa_mode_args+=(--set "serviceAccount.name=karpenter")
  else
    sa_mode_args+=(--set "serviceAccount.create=true")
    sa_mode_args+=(--set "serviceAccount.name=karpenter")
    sa_mode_args+=(--set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${controller_role_arn}")
  fi

  helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --version "${KARPENTER_VERSION}" \
    --namespace karpenter \
    --create-namespace \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${interruption_queue}" \
    "${sa_mode_args[@]}" \
    --wait --timeout 10m >/dev/null

  log "Applying Karpenter EC2NodeClass + NodePool"
  sed \
    -e "s/__NODE_ROLE__/${node_role}/g" \
    -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
    "${ROOT_DIR}/k8s/karpenter/nodeclass-nodepool.yaml" \
    | kubectl_ctx apply -f - >/dev/null

  kubectl_ctx -n karpenter rollout status deploy/karpenter --timeout=10m
}

ensure_amp_workspace() {
  log "Ensuring AMP workspace (${AMP_ALIAS}) exists"
  local ws_id
  ws_id="$(
    aws_cli amp list-workspaces \
      | jq -r --arg a "${AMP_ALIAS}" '.workspaces[] | select(.alias==$a) | .workspaceId' \
      | head -n 1
  )"

  if [[ -z "${ws_id}" || "${ws_id}" == "null" ]]; then
    ws_id="$(aws_cli amp create-workspace --alias "${AMP_ALIAS}" | jq -r .workspaceId)"
    log "Created AMP workspace: ${ws_id}"
  else
    log "Found AMP workspace: ${ws_id}"
  fi

  log "Waiting for AMP workspace to be ACTIVE"
  local deadline=$((SECONDS + 600))
  while :; do
    local status
    status="$(aws_cli amp describe-workspace --workspace-id "${ws_id}" | jq -r '.workspace.status.statusCode')"
    if [[ "${status}" == "ACTIVE" ]]; then
      break
    fi
    if (( SECONDS > deadline )); then
      die "AMP workspace did not become ACTIVE within 10 minutes (status=${status})"
    fi
    sleep 5
  done
  echo "${ws_id}"
}

ensure_prometheus_irsa_for_amp() {
  local amp_ws_id="$1"
  log "Creating/Updating IRSA role for Prometheus remote_write to AMP"

  local role_name="PrometheusRemoteWriteRole-${CLUSTER_NAME}"
  local ns="${MON_NAMESPACE}"
  local sa="prometheus-amp"

  local policy_name="PrometheusRemoteWritePolicy-${CLUSTER_NAME}"
  local policy_file
  policy_file="$(mktemp)"
  cat >"${policy_file}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["aps:RemoteWrite"],
      "Resource": "*"
    }
  ]
}
EOF

  local existing_policy_arn
  existing_policy_arn="$(
    aws --profile "${AWS_PROFILE}" iam list-policies --scope Local \
      | jq -r --arg n "${policy_name}" '.Policies[] | select(.PolicyName==$n) | .Arn' \
      | head -n 1
  )"

  if [[ -z "${existing_policy_arn}" || "${existing_policy_arn}" == "null" ]]; then
    existing_policy_arn="$(
      aws --profile "${AWS_PROFILE}" iam create-policy \
        --policy-name "${policy_name}" \
        --policy-document "file://${policy_file}" \
        | jq -r .Policy.Arn
    )"
    log "Created IAM policy: ${existing_policy_arn}"
  else
    if ! aws --profile "${AWS_PROFILE}" iam create-policy-version \
      --policy-arn "${existing_policy_arn}" \
      --policy-document "file://${policy_file}" \
      --set-as-default >/dev/null 2>&1; then
      ensure_policy_version_capacity "${existing_policy_arn}"
      aws --profile "${AWS_PROFILE}" iam create-policy-version \
        --policy-arn "${existing_policy_arn}" \
        --policy-document "file://${policy_file}" \
        --set-as-default >/dev/null
    fi
    log "Updated IAM policy: ${existing_policy_arn}"
  fi
  rm -f "${policy_file}"

  [[ -n "${existing_policy_arn}" && "${existing_policy_arn}" != "null" ]] || die "Failed to create or locate IAM policy for Prometheus remote_write"

  kubectl_ctx get ns "${ns}" >/dev/null 2>&1 || kubectl_ctx create ns "${ns}" >/dev/null

  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --namespace "${ns}" \
    --name "${sa}" \
    --role-name "${role_name}" \
    --attach-policy-arn "${existing_policy_arn}" \
    --override-existing-serviceaccounts \
    --approve >/dev/null

  local role_arn
  role_arn="$(aws --profile "${AWS_PROFILE}" iam get-role --role-name "${role_name}" | jq -r .Role.Arn)"
  echo "${role_arn}"
}

install_kube_prometheus_stack_remote_write() {
  local amp_ws_id="$1"
  local prom_role_arn="$2"

  log "Installing kube-prometheus-stack (Prometheus) with remote_write → AMP"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null

  local release="kps"
  kubectl_ctx get ns "${MON_NAMESPACE}" >/dev/null 2>&1 || kubectl_ctx create ns "${MON_NAMESPACE}" >/dev/null

  helm upgrade --install "${release}" prometheus-community/kube-prometheus-stack \
    --namespace "${MON_NAMESPACE}" \
    --set "prometheus.serviceAccount.create=true" \
    --set "prometheus.serviceAccount.name=prometheus-amp" \
    --set "prometheus.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${prom_role_arn}" \
    --set "prometheus.prometheusSpec.externalLabels.cluster=${CLUSTER_NAME}" \
    --set "prometheus.prometheusSpec.remoteWrite[0].url=https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${amp_ws_id}/api/v1/remote_write" \
    --set "prometheus.prometheusSpec.remoteWrite[0].sigv4.region=${AWS_REGION}" \
    --set "prometheus.prometheusSpec.remoteWrite[0].queueConfig.maxSamplesPerSend=1000" \
    --set "prometheus.prometheusSpec.remoteWrite[0].queueConfig.maxShards=10" \
    --wait --timeout 15m >/dev/null

  kubectl_ctx -n "${MON_NAMESPACE}" rollout status deploy/"${release}"-kube-state-metrics --timeout=10m
  if kubectl_ctx -n "${MON_NAMESPACE}" get deploy/"${release}"-kube-prometheus-stack-operator >/dev/null 2>&1; then
    kubectl_ctx -n "${MON_NAMESPACE}" rollout status deploy/"${release}"-kube-prometheus-stack-operator --timeout=10m
  fi
}

ensure_amg_workspace() {
  log "Ensuring AMG workspace (${AMG_NAME}) exists"

  local ws_id
  ws_id="$(
    aws_cli grafana list-workspaces \
      | jq -r --arg n "${AMG_NAME}" '.workspaces[] | select(.name==$n) | .id' \
      | head -n 1
  )"

  if [[ -z "${ws_id}" || "${ws_id}" == "null" ]]; then
    # For SERVICE_MANAGED + CURRENT_ACCOUNT, the API requires a workspace role ARN.
    # Create (or reuse) a role that AMG can assume, then attach AMP query permissions later.
    local ws_role_name="AMGWorkspaceRole-${CLUSTER_NAME}"
    local ws_role_arn
    ws_role_arn="$(aws --profile "${AWS_PROFILE}" iam get-role --role-name "${ws_role_name}" 2>/dev/null | jq -r .Role.Arn || true)"
    if [[ -z "${ws_role_arn}" || "${ws_role_arn}" == "null" ]]; then
      local trust_file
      trust_file="$(mktemp)"
      cat >"${trust_file}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "grafana.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
      ws_role_arn="$(
        aws --profile "${AWS_PROFILE}" iam create-role \
          --role-name "${ws_role_name}" \
          --assume-role-policy-document "file://${trust_file}" \
          | jq -r .Role.Arn
      )"
      rm -f "${trust_file}"
      [[ -n "${ws_role_arn}" && "${ws_role_arn}" != "null" ]] || die "Failed to create IAM role for AMG workspace"
      log "Created AMG workspace role: ${ws_role_arn}"
    else
      log "Reusing existing AMG workspace role: ${ws_role_arn}"
    fi

    ws_id="$(
      aws_cli grafana create-workspace \
        --workspace-name "${AMG_NAME}" \
        --account-access-type CURRENT_ACCOUNT \
        --authentication-providers "${AMG_AUTH_PROVIDER}" \
        --permission-type SERVICE_MANAGED \
        --workspace-role-arn "${ws_role_arn}" \
        --workspace-data-sources PROMETHEUS \
        --workspace-notification-destinations SNS \
        | jq -r .workspace.id
    )"
    [[ -n "${ws_id}" && "${ws_id}" != "null" ]] || die "Failed to create AMG workspace (check Identity Center/SAML setup)."
    log "Created AMG workspace: ${ws_id}"
  else
    log "Found AMG workspace: ${ws_id}"
  fi

  log "Waiting for AMG workspace to be ACTIVE and have an endpoint"
  local deadline=$((SECONDS + 900))
  while :; do
    local d
    d="$(aws_cli grafana describe-workspace --workspace-id "${ws_id}")"
    local status endpoint
    status="$(jq -r '.workspace.status' <<<"${d}")"
    endpoint="$(jq -r '.workspace.endpoint' <<<"${d}")"
    if [[ "${status}" == "ACTIVE" && -n "${endpoint}" && "${endpoint}" != "null" ]]; then
      break
    fi
    if (( SECONDS > deadline )); then
      die "AMG workspace did not become ACTIVE within 15 minutes (status=${status}, endpoint=${endpoint})"
    fi
    sleep 10
  done
  echo "${ws_id}"
}

attach_amp_query_perms_to_amg_role() {
  local amg_ws_id="$1"
  local amp_ws_id="$2"

  log "Attaching AMP query permissions to AMG workspace role"
  local ws
  ws="$(aws_cli grafana describe-workspace --workspace-id "${amg_ws_id}")"

  local amg_role_arn
  amg_role_arn="$(jq -r '.workspace.workspaceRoleArn // .workspace.iamRoleArn // .workspace.roleArn // empty' <<<"${ws}")"
  [[ -n "${amg_role_arn}" && "${amg_role_arn}" != "null" ]] || die "Could not determine AMG workspace role ARN"

  local amg_role_name
  amg_role_name="$(awk -F/ '{print $NF}' <<<"${amg_role_arn}")"

  local policy_name="AMGQueryAMP-${CLUSTER_NAME}"
  local policy_file
  policy_file="$(mktemp)"
  cat >"${policy_file}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "aps:QueryMetrics",
        "aps:GetLabels",
        "aps:GetSeries",
        "aps:GetMetricMetadata",
        "aps:ListWorkspaces",
        "aps:DescribeWorkspace"
      ],
      "Resource": "arn:aws:aps:${AWS_REGION}:${ACCOUNT_ID}:workspace/${amp_ws_id}"
    }
  ]
}
EOF

  local policy_arn
  policy_arn="$(
    aws --profile "${AWS_PROFILE}" iam list-policies --scope Local \
      | jq -r --arg n "${policy_name}" '.Policies[] | select(.PolicyName==$n) | .Arn' \
      | head -n 1
  )"

  if [[ -z "${policy_arn}" || "${policy_arn}" == "null" ]]; then
    policy_arn="$(
      aws --profile "${AWS_PROFILE}" iam create-policy \
        --policy-name "${policy_name}" \
        --policy-document "file://${policy_file}" \
        | jq -r .Policy.Arn
    )"
  else
    if ! aws --profile "${AWS_PROFILE}" iam create-policy-version \
      --policy-arn "${policy_arn}" \
      --policy-document "file://${policy_file}" \
      --set-as-default >/dev/null 2>&1; then
      ensure_policy_version_capacity "${policy_arn}"
      aws --profile "${AWS_PROFILE}" iam create-policy-version \
        --policy-arn "${policy_arn}" \
        --policy-document "file://${policy_file}" \
        --set-as-default >/dev/null
    fi
  fi
  rm -f "${policy_file}"

  aws --profile "${AWS_PROFILE}" iam attach-role-policy --role-name "${amg_role_name}" --policy-arn "${policy_arn}" >/dev/null || true
}

amg_configure_amp_datasource_and_dashboards() {
  local amg_ws_id="$1"
  local amp_ws_id="$2"

  log "Configuring AMG datasource + dashboards via Grafana API"

  local endpoint
  endpoint="$(aws_cli grafana describe-workspace --workspace-id "${amg_ws_id}" | jq -r .workspace.endpoint)"
  [[ -n "${endpoint}" && "${endpoint}" != "null" ]] || die "Could not determine AMG endpoint"
  if [[ "${endpoint}" != http* ]]; then
    endpoint="https://${endpoint}"
  fi

  local api_key
  local key_name
  key_name="bootstrap-${CLUSTER_NAME}-$(date +%s)"
  api_key="$(
    aws_cli grafana create-workspace-api-key \
      --workspace-id "${amg_ws_id}" \
      --key-name "${key_name}" \
      --key-role ADMIN \
      --seconds-to-live 86400 \
      | jq -r .key
  )"

  local ds_name="amp"
  local ds_payload
  ds_payload="$(cat <<EOF
{
  "name": "${ds_name}",
  "type": "prometheus",
  "access": "proxy",
  "url": "https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${amp_ws_id}",
  "isDefault": true,
  "jsonData": {
    "httpMethod": "POST",
    "sigV4Auth": true,
    "sigV4Region": "${AWS_REGION}",
    "sigV4AuthType": "default"
  }
}
EOF
)"

  # Create datasource if missing (idempotent)
  if ! curl -fsS -H "Authorization: Bearer ${api_key}" "${endpoint}/api/datasources/name/${ds_name}" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    local code
    code="$(
      curl -sS -o "${tmp}" -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        "${endpoint}/api/datasources" \
        -d "${ds_payload}" || true
    )"
    if [[ "${code}" != "200" && "${code}" != "409" ]]; then
      log "AMG datasource create returned HTTP ${code}: $(cat "${tmp}")"
    fi
    rm -f "${tmp}"
  fi

  import_dashboard() {
    local dashboard_id="$1"
    local rev="$2"
    local title_suffix="$3"

    local dash_json
    dash_json="$(curl -fsSL "https://grafana.com/api/dashboards/${dashboard_id}/revisions/${rev}/download")"
    # Many community dashboards use input placeholders like ${DS_PROMETHEUS}. When importing via API,
    # Grafana won't prompt for input mapping, so we rewrite placeholders to our datasource name.
    dash_json="$(jq -c --arg ds "${ds_name}" '
      walk(
        if type=="string" and (.=="${DS_PROMETHEUS}" or .=="${DS_PROMETHEUS_K8S}" or .=="${DS_PROMETHEUS_K8S_CLUSTER}")
        then $ds
        else .
        end
      )
    ' <<<"${dash_json}")"

    curl -fsS -X POST \
      -H "Authorization: Bearer ${api_key}" \
      -H "Content-Type: application/json" \
      "${endpoint}/api/dashboards/db" \
      -d "$(jq -c --arg t "${title_suffix}" '{dashboard: ., folderId:0, overwrite:true, message:("import "+$t)}' <<<"${dash_json}")" \
      >/dev/null
  }

  # Popular, broadly compatible dashboards (kube-prometheus-stack metrics):
  import_dashboard 1860 37 "node-exporter-full" || true
  import_dashboard 14436 1 "kubernetes-compute-resources-cluster" || true
}

deploy_demo_workload() {
  log "Deploying demo StatefulSet + HPA + load generator"
  kubectl_ctx apply -f "${ROOT_DIR}/k8s/demo/namespace.yaml" >/dev/null
  kubectl_ctx apply -f "${ROOT_DIR}/k8s/demo/statefulset.yaml" >/dev/null
  kubectl_ctx apply -f "${ROOT_DIR}/k8s/demo/hpa.yaml" >/dev/null
  kubectl_ctx -n "${DEMO_NAMESPACE}" delete job loadgen --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl_ctx apply -f "${ROOT_DIR}/k8s/demo/loadgen-job.yaml" >/dev/null
  kubectl_ctx -n "${DEMO_NAMESPACE}" rollout status statefulset/demo-worker --timeout=10m
}

main() {
  ensure_oidc_provider
  install_metrics_server
  ensure_metrics_api_available
  install_ebs_csi_addon
  apply_storageclass_gp3

  install_karpenter

  local amp_ws_id
  amp_ws_id="$(ensure_amp_workspace)"

  local prom_role_arn
  prom_role_arn="$(ensure_prometheus_irsa_for_amp "${amp_ws_id}")"
  install_kube_prometheus_stack_remote_write "${amp_ws_id}" "${prom_role_arn}"

  local amg_ws_id
  amg_ws_id="$(ensure_amg_workspace)"
  attach_amp_query_perms_to_amg_role "${amg_ws_id}" "${amp_ws_id}"
  amg_configure_amp_datasource_and_dashboards "${amg_ws_id}" "${amp_ws_id}"

  deploy_demo_workload

  log "Bootstrap complete."
  log "Demo namespace: ${DEMO_NAMESPACE}"
  log "Monitoring namespace: ${MON_NAMESPACE}"
  log "AMP alias: ${AMP_ALIAS}"
  log "AMG name: ${AMG_NAME}"
}

main "$@"

