# EKS StatefulSet + HPA + Karpenter + EBS (gp3) + AMP/AMG Demo

This repo bootstraps a **simple but real-world-worthy** demo on an existing EKS cluster:

- **StatefulSet**: stable pod identities + **per-pod EBS volumes** via `volumeClaimTemplates`
- **HPA**: scales replicas based on CPU (Metrics Server)
- **Karpenter**: automatically adds/removes nodes so the StatefulSet can scale
- **Prometheus/Grafana**: in-cluster Prometheus scrapes metrics and **remote_write → Amazon Managed Prometheus (AMP)**; **Amazon Managed Grafana (AMG)** is configured (datasource + dashboards) via API

The “real world” story is a **durable-spooling worker**: each replica has its own disk for buffering/checkpointing and can scale horizontally with load.

## Prereqs

- `aws` (v2), `kubectl`, `helm`, `eksctl`, `jq`
- AWS profile with permissions to create IAM/CloudFormation/AMP/AMG resources
- An existing EKS cluster

## Quickstart (your defaults)

```bash
export AWS_PROFILE=adotobserve
export AWS_REGION=us-east-1
export CLUSTER_NAME=tinyllama-eks

./scripts/bootstrap.sh
```

### Watch the demo scale

```bash
kubectl -n demo-stateful-hpa get pods -w
kubectl -n demo-stateful-hpa get hpa -w
kubectl get nodes -w

kubectl -n demo-stateful-hpa get pvc
kubectl -n demo-stateful-hpa get statefulset demo-worker -o wide
```

## Cleanup

```bash
export AWS_PROFILE=adotobserve
export AWS_REGION=us-east-1
export CLUSTER_NAME=tinyllama-eks

./scripts/cleanup.sh
```

## What gets installed / created

### Cluster-side

- Metrics Server
- EBS CSI driver (EKS add-on)
- StorageClass `ebs-gp3` (non-default, `WaitForFirstConsumer`)
- Karpenter controller + `EC2NodeClass` + `NodePool`
- Namespace `demo-stateful-hpa` with:
  - headless service + StatefulSet `demo-worker` (PVC per replica on `ebs-gp3`)
  - HPA v2 targeting the StatefulSet
  - load-generator job
- Namespace `monitoring` with kube-prometheus-stack (Prometheus + kube-state-metrics) configured for AMP remote_write

### AWS-side

- Karpenter CloudFormation stack (controller/node IAM + interruption queue)
- IRSA roles for:
  - EBS CSI controller
  - Prometheus remote_write to AMP
- AMP workspace + AMG workspace (and AMG datasource/dashboards via API)

## Notes

- This is designed to be **idempotent-ish** (safe to rerun). If something already exists, scripts try to update/reuse it.
- For AMG auth/access, the scripts create the workspace but you may need to grant yourself access in the AWS console depending on your org setup.

## Troubleshooting

### Grafana dashboards are empty

First, confirm Prometheus is successfully remote-writing to AMP:

```bash
kubectl -n monitoring logs prometheus-kps-kube-prometheus-stack-prometheus-0 -c prometheus --since=10m | tail -n 50
```

If you see `403 Forbidden` mentioning `aps:RemoteWrite`, it means the credentials Prometheus is using don’t have permission to ingest to AMP.

- **Quick demo fix**: attach the AWS managed policy `AmazonPrometheusRemoteWriteAccess` (allows `aps:RemoteWrite` on `*`) to the IAM role your EKS worker nodes are using.
- **Best-practice fix**: ensure your cluster has a working pod-identity / IRSA credential injection mechanism so the Prometheus pod actually uses the annotated ServiceAccount IAM role.

