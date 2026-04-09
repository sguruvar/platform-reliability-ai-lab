## What’s enabled

- **Metrics (AMP)**: In-cluster Prometheus scrapes Triton and **remote_writes to Amazon Managed Prometheus (AMP)**.
- **Tracing (Jaeger)**: Triton OpenTelemetry tracing exports to Jaeger via OTLP/HTTP (`4318`).
- **Logs**:
  - `kubectl logs -n tinyllama deploy/tinyllama-triton-hf`
  - `kubectl logs -n tinyllama deploy/tinyllama-triton-vllm`

## Endpoints created

- **AMP workspace**: `ws-935e5402-9908-4935-9a1b-dd201b3fd023`
  - **Prom endpoint**: `https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-935e5402-9908-4935-9a1b-dd201b3fd023/`
- **AMG workspace**: `g-e0027048fc`
  - **URL**: `https://g-e0027048fc.grafana-workspace.us-east-1.amazonaws.com`
- **Jaeger internal LB (for AMG datasource)**:
  - `http://internal-a49065c7705dd4af38921167a7fd827e-936911889.us-east-1.elb.amazonaws.com:16686`

## Prometheus (in-cluster)

- **Service**: `observability/prometheus.yaml` deploys Prometheus in namespace `observability`.
- **Scrape targets**:
  - `tinyllama-triton-hf-metrics.tinyllama.svc.cluster.local:8002`
  - `tinyllama-triton-vllm-metrics.tinyllama.svc.cluster.local:8002`
- **Remote write**: AMP via SigV4 (configured in `observability/prometheus.yaml`).

Port-forward:

```bash
kubectl -n observability port-forward svc/prometheus 9090:9090
```

Then open `http://localhost:9090` and search for metrics like `nv_gpu_utilization` or `triton_request_*`.

## Jaeger (in-cluster)

- **Collector**: `jaeger-collector.observability:4318` (OTLP HTTP)
- **Query UI**: `jaeger-query.observability:16686`
- **Internal LB for AMG**: `jaeger-query-internal` (created by `observability/jaeger.yaml`)

Port-forward:

```bash
kubectl -n observability port-forward svc/jaeger-query 16686:16686
```

Then open `http://localhost:16686` and search for service **`tinyllama-triton`**.
You’ll typically see:
- `tinyllama-triton-hf`
- `tinyllama-triton-vllm`

## AMG (Amazon Managed Grafana) wiring

- **Prometheus datasource (AMP)**:
  - AMG workspace is VPC-attached; we created VPC interface endpoints for `aps-workspaces` and `sts` so SigV4 works without NAT.
  - Datasource name: `AMP` (type `prometheus`, SigV4 enabled).
  - Note: when testing via Grafana proxy, use **POST**:

```bash
curl -sS -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -X POST "https://g-e0027048fc.grafana-workspace.us-east-1.amazonaws.com/api/datasources/proxy/<AMP_ID>/api/v1/query" \
  --data "query=up"
```

- **Jaeger datasource**:
  - AMG can use Jaeger as a datasource, but it must be reachable from AMG (again usually VPC access + internal LB in front of `jaeger-query`).
  - Datasource name: `Jaeger` pointing at the internal ELB above.

## Default dashboard

- **HF baseline dashboard JSON**: `observability/dashboards/tinyllama-hf.json`
- **vLLM dashboard JSON**: `observability/dashboards/tinyllama-vllm.json`
- **Compare dashboard JSON**: `observability/dashboards/tinyllama-compare.json`

Import both into Grafana so you can compare side-by-side.

Note: for apples-to-apples runs, set the dashboard variables:
- `target_rps` = your sequences/sec target
- `tokens_per_request` = use the same `MAX_TOKENS` you used in the load test (HF tokens/s is estimated from this)

## Generate traffic (so charts move)

Run traffic separately for each deployment (so the dashboards reflect apples-to-apples load).

### HF baseline (python backend `infer` with `text_input`)

```bash
LB=$(kubectl -n tinyllama get svc tinyllama-triton-hf-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TRITON_HTTP="http://$LB:8000" TRITON_MODEL=tinyllama_hf TRITON_REQUEST=infer_text \
  MODE=prompt PROMPT="Tell me a joke" MAX_TOKENS=64 TEMPERATURE=0.7 DURATION_S=300 CONCURRENCY=4 RPS=2 python3 loadgen/traffic_gen.py
```

### vLLM (`generate`)

```bash
LB=$(kubectl -n tinyllama get svc tinyllama-triton-vllm-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TRITON_HTTP="http://$LB:8000" TRITON_MODEL=tinyllama_vllm TRITON_REQUEST=generate \
  MODE=prompt PROMPT="Tell me a joke" MAX_TOKENS=64 TEMPERATURE=0.7 DURATION_S=300 CONCURRENCY=4 RPS=2 python3 loadgen/traffic_gen.py
```

### Side-by-side 15 minutes @ 10 RPS each

```bash
DURATION_S=900 CONCURRENCY=8 RPS=10 MAX_TOKENS=32 ./loadgen/run_compare_traffic.sh
```


