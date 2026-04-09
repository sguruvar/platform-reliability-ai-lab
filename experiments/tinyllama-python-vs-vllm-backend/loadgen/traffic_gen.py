import argparse
import os
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Lock

import numpy as np
import requests
from typing import Optional


def infer_one(triton_http: str, model_name: str, input_ids: list[int], timeout_s: float) -> np.ndarray:
    payload = {
        "inputs": [
            {
                "name": "input_ids",
                "shape": [1, len(input_ids)],
                "datatype": "INT64",
                "data": input_ids,
            }
        ],
        "outputs": [{"name": "logits_last"}],
    }
    r = requests.post(f"{triton_http}/v2/models/{model_name}/infer", json=payload, timeout=timeout_s)
    if r.status_code != 200:
        raise RuntimeError(f"{r.status_code}: {r.text[:300]}")
    j = r.json()
    outs = j.get("outputs") or []
    for o in outs:
        if o.get("name") == "logits_last":
            data = o.get("data")
            if data is None:
                raise RuntimeError("Missing logits_last.data in response")
            arr = np.asarray(data, dtype=np.float32).reshape(-1)
            return arr
    raise RuntimeError("Missing logits_last output in response")


def infer_text_one(
    triton_http: str,
    model_name: str,
    text_input: str,
    *,
    timeout_s: float,
) -> None:
    payload = {
        "inputs": [
            {
                "name": "text_input",
                "shape": [1],
                "datatype": "BYTES",
                "data": [text_input],
            }
        ],
        "outputs": [{"name": "text_output"}],
    }
    r = requests.post(f"{triton_http}/v2/models/{model_name}/infer", json=payload, timeout=timeout_s)
    if r.status_code != 200:
        raise RuntimeError(f"{r.status_code}: {r.text[:300]}")
    j = r.json()
    outs = j.get("outputs") or []
    for o in outs:
        if o.get("name") == "text_output":
            _ = o.get("data")
            return
    raise RuntimeError("Missing text_output output in response")


def generate_one(
    triton_http: str,
    model_name: str,
    text_input: str,
    *,
    max_tokens: int,
    temperature: float,
    top_p: Optional[float],
    timeout_s: float,
) -> None:
    params: dict[str, object] = {"stream": False, "max_tokens": int(max_tokens), "temperature": float(temperature)}
    if top_p is not None:
        params["top_p"] = float(top_p)
    payload = {"text_input": text_input, "parameters": params}
    r = requests.post(f"{triton_http}/v2/models/{model_name}/generate", json=payload, timeout=timeout_s)
    if r.status_code != 200:
        raise RuntimeError(f"{r.status_code}: {r.text[:300]}")
    _ = r.json().get("text_output")


def build_synthetic_ids(seq_len: int, vocab_size: int = 32000) -> list[int]:
    seq_len = int(max(seq_len, 1))
    return np.random.randint(0, vocab_size, size=(seq_len,), dtype=np.int64).tolist()


def sample_next_token_id(
    logits: np.ndarray,
    *,
    temperature: float,
    top_p: Optional[float],
    rng: np.random.Generator,
) -> int:
    if temperature <= 0:
        return int(np.argmax(logits))

    x = logits.astype(np.float64) / float(temperature)
    x = x - float(np.max(x))
    p = np.exp(x)
    p = p / float(np.sum(p))

    if top_p is not None and 0.0 < top_p < 1.0:
        idx = np.argsort(p)[::-1]
        p_sorted = p[idx]
        cdf = np.cumsum(p_sorted)
        cutoff = int(np.searchsorted(cdf, float(top_p), side="left"))
        cutoff = int(min(max(cutoff, 0), len(idx) - 1))
        keep = np.zeros_like(p_sorted, dtype=bool)
        keep[: cutoff + 1] = True
        idx_keep = idx[keep]
        p_keep = p[idx_keep]
        p_keep = p_keep / float(np.sum(p_keep))
        return int(rng.choice(idx_keep, p=p_keep))

    return int(rng.choice(len(p), p=p))


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate steady inference traffic to Triton.")
    ap.add_argument("--triton-http", default=os.getenv("TRITON_HTTP", "http://localhost:8000"))
    ap.add_argument("--model", default=os.getenv("TRITON_MODEL", "tinyllama"))
    ap.add_argument(
        "--request",
        choices=["infer", "infer_text", "generate"],
        default=os.getenv("TRITON_REQUEST", "infer"),
        help="Triton request type: 'infer' for tensor models, 'infer_text' for string models, 'generate' for vLLM backend.",
    )
    ap.add_argument("--mode", choices=["synthetic", "prompt"], default=os.getenv("MODE", "synthetic"))
    ap.add_argument("--seq-len", type=int, default=int(os.getenv("SEQ_LEN", "64")))
    ap.add_argument("--seq-len-jitter", type=int, default=int(os.getenv("SEQ_LEN_JITTER", "16")))
    ap.add_argument("--randomize", action="store_true", default=os.getenv("RANDOMIZE", "1") not in ("0", "false", "False"))
    ap.add_argument("--hf-model", default=os.getenv("HF_MODEL", "TinyLlama/TinyLlama-1.1B-Chat-v1.0"))
    ap.add_argument("--prompt", default=os.getenv("PROMPT", "Tell me why the sky is blue."))
    ap.add_argument("--system", dest="system_prompt", default=os.getenv("SYSTEM_PROMPT", "You are a helpful assistant. Answer concisely."))
    ap.add_argument("--max-tokens", type=int, default=int(os.getenv("MAX_TOKENS", "64")))
    ap.add_argument(
        "--decode-tokens",
        type=int,
        default=int(os.getenv("DECODE_TOKENS", "0")),
        help="For request=infer: number of autoregressive decode steps to run per scheduled fire (apples-to-apples vs generate).",
    )
    ap.add_argument("--max-context", type=int, default=int(os.getenv("MAX_CONTEXT", "512")))
    ap.add_argument("--temperature", type=float, default=float(os.getenv("TEMPERATURE", "0.7")))
    ap.add_argument("--top-p", type=float, default=float(os.getenv("TOP_P", "0.95")) if os.getenv("TOP_P") else None)
    ap.add_argument("--duration-s", type=int, default=int(os.getenv("DURATION_S", "180")))
    ap.add_argument("--concurrency", type=int, default=int(os.getenv("CONCURRENCY", "2")))
    ap.add_argument("--rps", type=float, default=float(os.getenv("RPS", "2")), help="Target total RPS (not per worker).")
    ap.add_argument("--timeout-s", type=float, default=float(os.getenv("TIMEOUT_S", "30")))
    args = ap.parse_args()

    lock = Lock()

    base_ids: list[int] | None = None
    base_text: str | None = None

    if args.mode == "prompt":
        if args.request == "infer":
            from transformers import AutoTokenizer  # imported lazily on purpose

            tokenizer = AutoTokenizer.from_pretrained(args.hf_model)
            if getattr(tokenizer, "chat_template", None):
                messages = [
                    {"role": "system", "content": args.system_prompt},
                    {"role": "user", "content": args.prompt},
                ]
                txt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            else:
                txt = args.prompt
            ids = tokenizer.encode(txt, add_special_tokens=False)
            base_text = txt
            base_ids = ids[-128:]
        else:
            base_text = ""
            base_ids = None
    else:
        if args.request == "infer":
            base_ids = build_synthetic_ids(args.seq_len)
        else:
            base_text = ("x" * int(max(args.seq_len, 8))) + "\n"

    end_t = time.time() + args.duration_s
    interval = 1.0 / max(args.rps, 0.1)
    next_fire = time.time()

    ok = 0
    err = 0
    lat_ms = []

    def _make_request_payload():
        if args.request == "infer":
            assert base_ids is not None
            if args.mode == "prompt":
                if not args.randomize:
                    return list(base_ids)
                local = list(base_ids)
                for _ in range(8):
                    idx = int(np.random.randint(0, len(local)))
                    local[idx] = int(np.random.randint(0, 32000))
                return local

            if not args.randomize:
                return list(base_ids)

            base = int(args.seq_len)
            jitter = int(max(args.seq_len_jitter, 0))
            L = base + int(np.random.randint(-jitter, jitter + 1)) if jitter else base
            L = int(min(max(L, 8), 512))
            return build_synthetic_ids(L)

        if args.mode == "prompt":
            rid = int(np.random.randint(0, 1_000_000_000)) if args.randomize else 0
            obj = {
                "prompt": args.prompt,
                "system": args.system_prompt,
                "max_tokens": int(args.max_tokens),
                "temperature": float(args.temperature),
            }
            if args.top_p is not None:
                obj["top_p"] = float(args.top_p)
            if rid:
                obj["request_id"] = rid
            import json

            return json.dumps(obj, separators=(",", ":"))

        assert base_text is not None
        if not args.randomize:
            return base_text
        rid = int(np.random.randint(0, 1_000_000_000))
        return base_text + f"\n\nRequestID: {rid}\n"

    def _worker() -> None:
        nonlocal ok, err
        rng = np.random.default_rng()
        while time.time() < end_t:
            nonlocal next_fire
            with lock:
                now = time.time()
                if now < next_fire:
                    sleep_for = next_fire - now
                else:
                    sleep_for = 0.0
                    next_fire = now + interval
            if sleep_for > 0:
                time.sleep(sleep_for)

            payload = _make_request_payload()
            t0 = time.time()
            try:
                if args.request == "infer":
                    if args.decode_tokens > 0:
                        local_ids = list(payload)  # type: ignore[arg-type]
                        steps = int(max(args.decode_tokens, 1))
                        max_ctx = int(max(args.max_context, 16))
                        for _ in range(steps):
                            logits = infer_one(args.triton_http, args.model, local_ids, args.timeout_s)
                            next_id = sample_next_token_id(
                                logits,
                                temperature=float(args.temperature),
                                top_p=args.top_p,
                                rng=rng,
                            )
                            local_ids.append(int(next_id))
                            if len(local_ids) > max_ctx:
                                local_ids = local_ids[-max_ctx:]
                    else:
                        _ = infer_one(args.triton_http, args.model, payload, args.timeout_s)  # type: ignore[arg-type]
                elif args.request == "infer_text":
                    infer_text_one(
                        args.triton_http,
                        args.model,
                        payload,  # type: ignore[arg-type]
                        timeout_s=args.timeout_s,
                    )
                else:
                    generate_one(
                        args.triton_http,
                        args.model,
                        payload,  # type: ignore[arg-type]
                        max_tokens=args.max_tokens,
                        temperature=args.temperature,
                        top_p=args.top_p,
                        timeout_s=args.timeout_s,
                    )
                with lock:
                    ok += 1
                    lat_ms.append((time.time() - t0) * 1000.0)
            except Exception:
                with lock:
                    err += 1

    print(
        f"Sending traffic to {args.triton_http} model={args.model} request={args.request} mode={args.mode} "
        f"duration={args.duration_s}s concurrency={args.concurrency} target_rps={args.rps} randomize={args.randomize}",
        flush=True,
    )
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        for _ in range(args.concurrency):
            ex.submit(_worker)

    if lat_ms:
        p50 = float(np.percentile(lat_ms, 50))
        p95 = float(np.percentile(lat_ms, 95))
        p99 = float(np.percentile(lat_ms, 99))
    else:
        p50 = p95 = p99 = float("nan")
    print(f"done ok={ok} err={err} p50={p50:.1f}ms p95={p95:.1f}ms p99={p99:.1f}ms")


if __name__ == "__main__":
    main()

