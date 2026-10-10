import os
import threading
from typing import Tuple

class LLMEngine:
    def __init__(self):
        self.pipe = None
        self.model_id = os.getenv("MODEL_ID", "TinyLlama/TinyLlama-1.1B-Chat-v1.0")
        # "auto" = bfloat16 on GPU, float32 on CPU. Set "bfloat16" to halve CPU memory use.
        self.model_dtype = os.getenv("MODEL_DTYPE", "auto").lower()
        self.is_loading = False
        self.load_error = None
        # A single pipeline is not safe to drive from several threads at once, and
        # concurrent CPU inference only makes every request slower. Serialize access.
        self._inference_lock = threading.Lock()

    def is_ready(self) -> bool:
        """Returns True if the pipeline is loaded and ready for inference."""
        return self.pipe is not None

    def load_model(self):
        """Loads the model into memory. Lazy imports torch/transformers to keep server startup instantaneous."""
        try:
            self.is_loading = True
            self.load_error = None
            print(f"[INFO] Loading model '{self.model_id}' in background thread...")

            # Lazy import to keep Uvicorn boot instantaneous
            import torch
            from transformers import pipeline

            if self.model_dtype == "auto":
                dtype = torch.bfloat16 if torch.cuda.is_available() else torch.float32
            elif self.model_dtype in ("float32", "bfloat16", "float16"):
                dtype = getattr(torch, self.model_dtype)
            else:
                raise ValueError(f"Unsupported MODEL_DTYPE '{self.model_dtype}' (use auto, float32, bfloat16 or float16)")

            self.pipe = pipeline(
                "text-generation",
                model=self.model_id,
                dtype=dtype,
                device_map="auto" if torch.cuda.is_available() else None
            )
            self.is_loading = False
            print(f"[SUCCESS] Model '{self.model_id}' loaded successfully!")
        except Exception as e:
            self.is_loading = False
            self.load_error = str(e)
            print(f"[ERROR] Failed to load model '{self.model_id}': {e}")

    def load_model_async(self):
        """Spawns background thread to load model without blocking API startup."""
        thread = threading.Thread(target=self.load_model, daemon=True)
        thread.start()

    def generate(self, prompt: str, max_new_tokens: int = 256, temperature: float = 0.7) -> Tuple[str, int]:
        """Generates text based on the prompt. Returns (generated_text, generated_token_count)."""
        if not self.is_ready():
            if self.is_loading:
                raise RuntimeError("Model is currently loading into memory. Please retry shortly.")
            elif self.load_error:
                raise RuntimeError(f"Model failed to load: {self.load_error}")
            else:
                raise RuntimeError("Model is not loaded!")

        # Create a chat-like format for TinyLlama
        messages = [
            {"role": "system", "content": "You are a helpful AI assistant."},
            {"role": "user", "content": prompt},
        ]

        # Apply the chat template
        prompt_formatted = self.pipe.tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True
        )

        # Sampling with temperature 0 is rejected by transformers; treat it as greedy decoding.
        if temperature > 0:
            sampling_kwargs = {"do_sample": True, "temperature": temperature, "top_k": 50, "top_p": 0.95}
        else:
            sampling_kwargs = {"do_sample": False}

        with self._inference_lock:
            outputs = self.pipe(
                prompt_formatted,
                max_new_tokens=max_new_tokens,
                return_full_text=False,
                **sampling_kwargs
            )

        generated_text = outputs[0]["generated_text"].strip()
        token_count = len(self.pipe.tokenizer.encode(generated_text, add_special_tokens=False))
        return generated_text, token_count

# Create a global instance
llm_engine = LLMEngine()
