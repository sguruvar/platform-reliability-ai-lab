# Autoscaling Stateful Workloads on EKS: StatefulSet + HPA + EBS + Karpenter (with AMP/AMG)

If you’ve only ever autoscaled stateless Deployments, here’s a compact (but “real”) exercise that proves a key point:

**Stateful doesn’t mean static.**

In this demo you’ll run a **StatefulSet** that gets **one EBS volume per replica**, scale it with **HPA**, and let **Karpenter** add nodes when the cluster needs more capacity. For observability, Prometheus remote-writes into **Amazon Managed Prometheus (AMP)** and dashboards come from **Amazon Managed Grafana (AMG)**.

This is scripted so you can bootstrap/cleanup repeatedly.

---

## What you’re building (in one paragraph)

- A **Fortio** job sends HTTP load to a stable endpoint (`demo-worker` Service).
- The endpoint routes to an **nginx** worker pool implemented as a **StatefulSet**.
- Each replica has its own **EBS gp3 PVC** (RWO), demonstrating per-replica persistence.
- **HPA** scales replicas based on CPU.
- **Karpenter** adds nodes if new replicas can’t schedule.
- **Prometheus → AMP** stores metrics, and **AMG** visualizes them.

---

## The architecture diagram

Render from `diagrams/architecture.mmd` (see “Generate diagrams” below) and insert the exported image here.

---

## Why this is “real-world worthy”

The demo workload is intentionally simple (nginx), but the pattern is common:

- **Durable spooling workers** that buffer data locally
- **Sharded processors** where each replica owns a shard and keeps local checkpoints
- **Edge caches** where each replica’s disk reduces repeated downloads

The key is that each replica’s disk is *replica-local* (RWO) and the app tolerates scaling by design.

---

## Prereqs

- An existing EKS cluster
- Tools: `aws`, `kubectl`, `helm`, `eksctl`, `jq`, `curl`
- IAM permissions for EKS add-ons, IAM/IRSA, CloudFormation, AMP, AMG

---

## Bootstrap (scripted)

```bash
export AWS_PROFILE=adotobserve
export AWS_REGION=us-east-1
export CLUSTER_NAME=tinyllama-eks

./scripts/bootstrap.sh
```

---

## Run the demo (make the graphs move)

Re-run the load generator:

```bash
kubectl -n demo-stateful-hpa delete job loadgen --ignore-not-found=true
kubectl -n demo-stateful-hpa apply -f k8s/demo/loadgen-job.yaml
```

Watch scaling happen:

```bash
kubectl -n demo-stateful-hpa get hpa demo-worker -w
kubectl -n demo-stateful-hpa get pods -w
kubectl get nodes -w
kubectl -n demo-stateful-hpa get pvc
```

What you should see:

- **HPA** ramps replicas from 1 → 5 (or your configured max)
- **New pods** appear (`demo-worker-1..4`) and each gets its own PVC
- **Nodes** may increase if the cluster is tight (Karpenter)

---

## The scaling flow diagram

Render from `diagrams/scaling-flow.mmd` and embed it here.

---

## AMG: two queries that prove it’s working

In AMG → Explore, use datasource `amp`, time range “Last 15 minutes”.

**HPA replicas**

```promql
kube_horizontalpodautoscaler_status_current_replicas{namespace="demo-stateful-hpa",horizontalpodautoscaler="demo-worker"}
```

**CPU by pod (shows replicas sharing load)**

```promql
sum(rate(container_cpu_usage_seconds_total{namespace="demo-stateful-hpa",pod=~"demo-worker-.*",container="nginx"}[1m])) by (pod)
```

---

## Generate diagrams (PNG/SVG) for Medium

This repo includes Mermaid diagram sources plus a renderer:

```bash
chmod +x scripts/render-diagrams.sh
./scripts/render-diagrams.sh
```

Outputs land in `docs/diagrams/`:

- `architecture.png` / `architecture.svg`
- `scaling-flow.png` / `scaling-flow.svg`
- `business-flow.png` / `business-flow.svg`

---

## Cleanup

```bash
./scripts/cleanup.sh
```

Full AWS-side teardown:

```bash
FULL_TEARDOWN=1 ./scripts/cleanup.sh
```

