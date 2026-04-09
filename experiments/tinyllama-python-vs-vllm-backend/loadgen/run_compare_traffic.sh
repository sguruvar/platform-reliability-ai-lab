#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAFFIC_PY="$ROOT/loadgen/traffic_gen.py"

NS="${NS:-tinyllama}"
DURATION_S="${DURATION_S:-300}"
CONCURRENCY="${CONCURRENCY:-4}"
RPS="${RPS:-2}"
RPS_HF="${RPS_HF:-$RPS}"
RPS_VLLM="${RPS_VLLM:-$RPS}"
MATCH_RPS="${MATCH_RPS:-0}"
CALIBRATION_S="${CALIBRATION_S:-60}"

MODE_HF="${MODE_HF:-prompt}"
MODE_VLLM="${MODE_VLLM:-prompt}"

PROMPT="${PROMPT:-Tell me a joke}"
SYSTEM_PROMPT="${SYSTEM_PROMPT:-You are a helpful assistant. Answer concisely.}"
PROMPT_VLLM="${PROMPT_VLLM:-$PROMPT}"
PROMPT_HF="${PROMPT_HF:-$PROMPT}"
MAX_TOKENS="${MAX_TOKENS:-64}"
TEMPERATURE="${TEMPERATURE:-0.7}"
TOP_P="${TOP_P:-0.95}"

ENDPOINT_MODE="${ENDPOINT_MODE:-port-forward}" # port-forward | lb
HF_PORT="${HF_PORT:-18002}"
VLLM_PORT="${VLLM_PORT:-18001}"
PF_MANAGE="${PF_MANAGE:-1}" # for port-forward mode: start/stop port-forwards automatically

start_pf() {
  local svc="$1"
  local port="$2"
  local pidfile="$3"

  if curl -fsS "http://127.0.0.1:${port}/v2/health/ready" >/dev/null 2>&1; then
    echo "Port-forward already up on :$port"
    return 0
  fi

  echo "Starting port-forward: svc/${svc} :${port} -> :8000"
  kubectl -n "$NS" port-forward "svc/${svc}" "${port}:8000" >/tmp/"${svc}-${port}.pf.log" 2>&1 &
  echo $! >"$pidfile"

  for _ in {1..30}; do
    if curl -fsS "http://127.0.0.1:${port}/v2/health/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: port-forward to ${svc} did not become ready; see /tmp/${svc}-${port}.pf.log" >&2
  return 1
}

stop_pf() {
  local pidfile="$1"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(cat "$pidfile" || true)"
    rm -f "$pidfile"
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi
}

if [ "$ENDPOINT_MODE" = "port-forward" ] && [ "$PF_MANAGE" = "1" ]; then
  pf_hf="$(mktemp)"
  pf_vllm="$(mktemp)"
  trap 'stop_pf "$pf_hf"; stop_pf "$pf_vllm"' EXIT
  start_pf "tinyllama-triton-hf-svc" "$HF_PORT" "$pf_hf"
  start_pf "tinyllama-triton-vllm-svc" "$VLLM_PORT" "$pf_vllm"
fi

if [ "$ENDPOINT_MODE" = "lb" ]; then
  LB_HF="$(kubectl -n "$NS" get svc tinyllama-triton-hf-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  LB_VLLM="$(kubectl -n "$NS" get svc tinyllama-triton-vllm-svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  TRITON_HTTP_HF="http://${LB_HF}:8000"
  TRITON_HTTP_VLLM="http://${LB_VLLM}:8000"
  echo "HF LB:   $LB_HF"
  echo "vLLM LB: $LB_VLLM"
else
  TRITON_HTTP_HF="http://127.0.0.1:${HF_PORT}"
  TRITON_HTTP_VLLM="http://127.0.0.1:${VLLM_PORT}"
  echo "HF:   ${TRITON_HTTP_HF}"
  echo "vLLM: ${TRITON_HTTP_VLLM}"
fi

echo

if [ "$MATCH_RPS" = "1" ]; then
  echo "Calibrating achieved RPS for ${CALIBRATION_S}s at requested RPS_HF=${RPS_HF}, RPS_VLLM=${RPS_VLLM} ..."
  tmp_hf="$(mktemp)"
  tmp_vllm="$(mktemp)"

  TRITON_HTTP="$TRITON_HTTP_HF" TRITON_MODEL=tinyllama_hf TRITON_REQUEST=infer_text \
    MODE="$MODE_HF" PROMPT="$PROMPT_HF" SYSTEM_PROMPT="$SYSTEM_PROMPT" MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" TOP_P="$TOP_P" \
    DURATION_S="$CALIBRATION_S" CONCURRENCY="$CONCURRENCY" RPS="$RPS_HF" \
    python3 "$TRAFFIC_PY" >"$tmp_hf" 2>&1 &
  pid_hf=$!

  TRITON_HTTP="$TRITON_HTTP_VLLM" TRITON_MODEL=tinyllama_vllm TRITON_REQUEST=generate \
    MODE="$MODE_VLLM" PROMPT="$PROMPT_VLLM" SYSTEM_PROMPT="$SYSTEM_PROMPT" MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" TOP_P="$TOP_P" \
    DURATION_S="$CALIBRATION_S" CONCURRENCY="$CONCURRENCY" RPS="$RPS_VLLM" \
    python3 "$TRAFFIC_PY" >"$tmp_vllm" 2>&1 &
  pid_vllm=$!

  wait "$pid_hf" "$pid_vllm"

  matched="$(python3 - <<PY
import re, math
cal=int(${CALIBRATION_S})
def ok(path):
  txt=open(path,'r',errors='ignore').read()
  m=re.search(r'done\\s+ok=(\\d+)', txt)
  return int(m.group(1)) if m else 0
ok_hf=ok("${tmp_hf}")
ok_vllm=ok("${tmp_vllm}")
rps_hf=ok_hf/max(cal,1)
rps_vllm=ok_vllm/max(cal,1)
matched=min(rps_hf, rps_vllm)
matched=math.floor(matched*10)/10.0
print(matched)
PY
)"

  echo "Calibration complete. Using matched RPS=${matched} for BOTH."
  rm -f "$tmp_hf" "$tmp_vllm"
  RPS_HF="$matched"
  RPS_VLLM="$matched"
  echo
fi

TRITON_HTTP="$TRITON_HTTP_HF" TRITON_MODEL=tinyllama_hf TRITON_REQUEST=infer_text \
  MODE="$MODE_HF" PROMPT="$PROMPT_HF" SYSTEM_PROMPT="$SYSTEM_PROMPT" MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" TOP_P="$TOP_P" \
  DURATION_S="$DURATION_S" CONCURRENCY="$CONCURRENCY" RPS="$RPS_HF" \
  python3 "$TRAFFIC_PY" &
PID_HF=$!

TRITON_HTTP="$TRITON_HTTP_VLLM" TRITON_MODEL=tinyllama_vllm TRITON_REQUEST=generate \
  MODE="$MODE_VLLM" PROMPT="$PROMPT_VLLM" SYSTEM_PROMPT="$SYSTEM_PROMPT" MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" TOP_P="$TOP_P" \
  DURATION_S="$DURATION_S" CONCURRENCY="$CONCURRENCY" RPS="$RPS_VLLM" \
  python3 "$TRAFFIC_PY" &
PID_VLLM=$!

wait "$PID_HF" "$PID_VLLM"

