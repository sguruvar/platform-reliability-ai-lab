import json
import os
from typing import Any

import numpy as np
import torch
import triton_python_backend_utils as pb_utils
from transformers import AutoModelForCausalLM, AutoTokenizer


def _get_param(params: dict[str, Any], key: str, default: Any) -> Any:
    v = params.get(key, default)
    return default if v is None else v


class TritonPythonModel:
    def initialize(self, args):
        model_config = json.loads(args["model_config"])
        params = model_config.get("parameters", {})

        self.model_id = _get_param(params, "MODEL_ID", {"string_value": "TinyLlama/TinyLlama-1.1B-Chat-v1.0"}).get(
            "string_value", "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
        )
        self.default_system = _get_param(
            params, "SYSTEM_PROMPT", {"string_value": "You are a helpful assistant. Answer concisely."}
        ).get("string_value", "You are a helpful assistant. Answer concisely.")

        # Generation defaults (can be overridden per request via JSON in text_input).
        self.default_max_new_tokens = int(
            _get_param(params, "MAX_NEW_TOKENS", {"string_value": "16"}).get("string_value", "16")
        )
        self.default_temperature = float(
            _get_param(params, "TEMPERATURE", {"string_value": "0.7"}).get("string_value", "0.7")
        )
        self.default_top_p = float(_get_param(params, "TOP_P", {"string_value": "0.95"}).get("string_value", "0.95"))

        # Hugging Face cache controls (use emptyDir/PVC for speed).
        cache_dir = os.environ.get("HF_HOME") or os.environ.get("TRANSFORMERS_CACHE") or None

        self.tokenizer = AutoTokenizer.from_pretrained(self.model_id, cache_dir=cache_dir)
        if getattr(self.tokenizer, "pad_token_id", None) is None and getattr(self.tokenizer, "eos_token_id", None) is not None:
            self.tokenizer.pad_token_id = self.tokenizer.eos_token_id

        self.model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            torch_dtype=torch.float16,
            device_map="cuda",
            cache_dir=cache_dir,
        )
        self.model.eval()

    def execute(self, requests):
        responses = []
        for request in requests:
            inp = pb_utils.get_input_tensor_by_name(request, "text_input")
            raw = inp.as_numpy()[0]
            if isinstance(raw, (bytes, bytearray)):
                raw = raw.decode("utf-8", errors="ignore")
            text_input = str(raw)

            # Accept either a raw prompt string, or JSON:
            # {"prompt": "...", "system": "...", "max_tokens": 16, "temperature": 0.7, "top_p": 0.95}
            prompt = text_input
            system = self.default_system
            max_new_tokens = self.default_max_new_tokens
            temperature = self.default_temperature
            top_p = self.default_top_p

            if text_input and text_input.lstrip().startswith("{"):
                try:
                    obj = json.loads(text_input)
                    prompt = str(obj.get("prompt", prompt))
                    system = str(obj.get("system", system))
                    if obj.get("max_tokens") is not None:
                        max_new_tokens = int(obj["max_tokens"])
                    if obj.get("temperature") is not None:
                        temperature = float(obj["temperature"])
                    if obj.get("top_p") is not None:
                        top_p = float(obj["top_p"])
                except Exception:
                    # Fall back to treating it as a normal prompt string.
                    pass

            if getattr(self.tokenizer, "chat_template", None):
                messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
                rendered = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            else:
                rendered = prompt

            inputs = self.tokenizer(rendered, return_tensors="pt").to("cuda")
            with torch.inference_mode():
                out = self.model.generate(
                    **inputs,
                    max_new_tokens=max_new_tokens,
                    do_sample=(temperature > 0),
                    temperature=max(temperature, 1e-6),
                    top_p=top_p,
                    pad_token_id=self.tokenizer.pad_token_id,
                    eos_token_id=getattr(self.tokenizer, "eos_token_id", None),
                )
            decoded = self.tokenizer.decode(out[0], skip_special_tokens=False)

            resp = pb_utils.InferenceResponse(
                output_tensors=[pb_utils.Tensor("text_output", np.array([decoded], dtype=object))]
            )
            responses.append(resp)
        return responses

