# Stateful Doesn’t Mean Static: Autoscaling StatefulSet Pods on EKS

Most Kubernetes scaling tutorials stop at stateless Deployments. In real platforms, you’ll often run **stateful workers** too—things that buffer, checkpoint, shard, or cache locally.

This post is a practical exercise: a **StatefulSet** on EKS that still scales horizontally with an **HPA**, backed by **EBS volumes per replica**, with **Karpenter** scaling nodes when needed. Metrics go to **Amazon Managed Prometheus (AMP)** and dashboards are in **Amazon Managed Grafana (AMG)**.

Everything is scripted so you can rerun it as many times as you want.

---

## The business flow (no Kubernetes words)

Embed the diagram rendered from `diagrams/business-flow.mmd` here.

The story is:

- Traffic hits a stable endpoint.
- A worker pool handles requests.
- CPU rises under load.
- Autoscaling adds workers.
- Each worker has its own local disk for buffering/checkpointing.
- Metrics are collected and graphed.

---

## What the exercise deploys (concrete)

- **Fortio** Job generates HTTP load
- **Service** provides a stable target
- **StatefulSet** runs nginx, 1..5 replicas
- **EBS gp3 PVC** per replica (RWO) via `volumeClaimTemplates`
- **HPA** scales on CPU
- **Karpenter** adds nodes if pods are Pending
- **Prometheus** scrapes, remote_writes to AMP
- **AMG** queries AMP for dashboards

---

## Run it

Bootstrap:

```bash
export AWS_PROFILE=adotobserve
export AWS_REGION=us-east-1
export CLUSTER_NAME=tinyllama-eks

./scripts/bootstrap.sh
```

Generate load (to make graphs move):

```bash
kubectl -n demo-stateful-hpa delete job loadgen --ignore-not-found=true
kubectl -n demo-stateful-hpa apply -f k8s/demo/loadgen-job.yaml
```

Watch:

```bash
kubectl -n demo-stateful-hpa get hpa demo-worker -w
kubectl -n demo-stateful-hpa get pods -w
kubectl get nodes -w
kubectl -n demo-stateful-hpa get pvc
```

---

## The two “proof” graphs

In AMG → Explore (datasource `amp`):

**Replicas jump**

```promql
kube_horizontalpodautoscaler_status_current_replicas{namespace="demo-stateful-hpa",horizontalpodautoscaler="demo-worker"}
```

**CPU spreads across replicas**

```promql
sum(rate(container_cpu_usage_seconds_total{namespace="demo-stateful-hpa",pod=~"demo-worker-.*",container="nginx"}[1m])) by (pod)
```

---

## Generate diagrams for Substack

```bash
chmod +x scripts/render-diagrams.sh
./scripts/render-diagrams.sh
```

Upload images from `docs/diagrams/` into your Substack post.

---

## Cleanup

```bash
./scripts/cleanup.sh
```

