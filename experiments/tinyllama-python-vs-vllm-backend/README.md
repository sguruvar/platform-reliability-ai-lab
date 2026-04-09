## TinyLlama on Triton: Python backend vs vLLM backend

This repo is a small, reproducible benchmark to compare **two ways of serving the same TinyLlama chat model** on GPU using **NVIDIA Triton Inference Server**:

- **HF baseline**: Triton **Python backend** (`tinyllama_hf`) using Hugging Face `transformers` `generate()`
- **vLLM**: Triton **vLLM backend** (`tinyllama_vllm`) using vLLM continuous batching / PagedAttention

The goal is an apples-to-apples comparison of **latency** and **throughput** under the same load, with metrics in **Amazon Managed Prometheus (AMP)** and dashboards in **Amazon Managed Grafana (AMG)**.

### Repo layout

- **`deploy/`**: Kubernetes manifests
  - `deploy/triton-tinyllama.yaml`: deploys two Triton Deployments (HF + vLLM), Services, and PVCs (HF deps/cache + vLLM cache)
- **`observability/`**: Prometheus (remote_write to AMP) + Jaeger + dashboards
  - `observability/jaeger.yaml`
  - `observability/prometheus.yaml`
  - `observability/dashboards/` (Grafana dashboards as JSON; only 3 are intended)
- **`loadgen/`**: traffic generation
  - `loadgen/traffic_gen.py`
  - `loadgen/run_compare_traffic.sh`
- **`scripts/`**: bring-up / tear-down helpers
  - `scripts/bootstrap.sh`
  - `scripts/cleanup.sh`

### Prereqs

- `kubectl` configured to your EKS cluster
- GPU nodes available and NVIDIA device plugin installed
- `aws` CLI configured (for AMG dashboard import/cleanup)
- Python 3 for `loadgen/traffic_gen.py`

### Quickstart

Bootstrap (deploy + import dashboards):

```bash
./scripts/bootstrap.sh
```

Run side-by-side load (defaults: 5 minutes, 2 RPS):

```bash
./loadgen/run_compare_traffic.sh
```

Typical benchmark run (15 min @ 10 RPS each):

```bash
DURATION_S=900 CONCURRENCY=8 RPS=10 MAX_TOKENS=32 ./loadgen/run_compare_traffic.sh
```

Cleanup:

```bash
./scripts/cleanup.sh
```

### Notes / caveats

- **HF tokens/s is estimated** in the compare dashboard as:
  - `HF requests/s * tokens_per_request`
  - Set the `tokens_per_request` variable (dashboard textbox) to match your `MAX_TOKENS`.
- vLLM tokens/s uses real vLLM metrics (`vllm:generation_tokens_total`).
- HF has PVCs for cache + deps; vLLM has its own cache PVC so restarts don’t re-download.

### Write-up

See `ARTICLE.md` for a Medium-style post you can publish.

### Publishing to Medium

- **Draft source**: `ARTICLE.md`
- **Dashboards** (check in as JSON and link in the post):
  - `observability/dashboards/tinyllama-hf.json`
  - `observability/dashboards/tinyllama-vllm.json`
  - `observability/dashboards/tinyllama-compare.json`
- **Diagrams**: the Mermaid diagrams are already in `ARTICLE.md` (Medium supports Mermaid via embeds/plugins; otherwise screenshot them from GitHub preview and paste images).

Suggested publishing flow:

```bash
# Run a clean benchmark, then write against real numbers
./scripts/bootstrap.sh
DURATION_S=900 CONCURRENCY=8 RPS=10 MAX_TOKENS=32 ./loadgen/run_compare_traffic.sh
./scripts/cleanup.sh
```

