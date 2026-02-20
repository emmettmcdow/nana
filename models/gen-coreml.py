#!/usr/bin/env python3
"""Generate a CoreML model from a HuggingFace sentence-transformers model."""

import argparse
import coremltools as ct
from sentence_transformers import SentenceTransformer
import torch
import torch.nn as nn
import urllib.request
from pathlib import Path


class EmbeddingWrapper(nn.Module):
    """Wraps a sentence-transformers model to output only last_hidden_state.

    Mean pooling and normalization are done on the caller side (in Zig) so that
    the real attention mask is used instead of the one baked in by torch.jit.trace.
    """

    def __init__(self, st_model):
        super().__init__()
        self.transformer = st_model[0].auto_model

    def forward(self, input_ids, attention_mask):
        outputs = self.transformer(input_ids=input_ids, attention_mask=attention_mask)
        return outputs.last_hidden_state


def main():
    parser = argparse.ArgumentParser(
        description="Generate CoreML model from HuggingFace model"
    )
    parser.add_argument(
        "model",
        help="HuggingFace model path (e.g., sentence-transformers/all-mpnet-base-v2)",
    )
    parser.add_argument(
        "--output",
        "-o",
        help="Output path for .mlpackage (default: derived from model name)",
    )
    parser.add_argument(
        "--seq-length", type=int, default=128, help="Max sequence length (default: 128)"
    )
    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        help="Trust remote code for custom models",
    )
    args = parser.parse_args()

    model_name = args.model
    hf_base = f"https://huggingface.co/{model_name}/resolve/main"

    # Derive output directory and mlpackage path from model name.
    # Structure: <model_dir>/<model_name>.mlpackage + <model_dir>/tokenizer.json
    if args.output:
        output_dir = Path(args.output)
    else:
        output_dir = Path(model_name.replace("/", "_").replace("-", "_"))

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / (output_dir.name + ".mlpackage")

    print(f"Loading model: {model_name}")
    model = SentenceTransformer(
        model_name, trust_remote_code=args.trust_remote_code, device="cpu"
    )
    model.eval()

    wrapper = EmbeddingWrapper(model)
    wrapper.eval()

    max_seq_length = args.seq_length
    example_input_ids = torch.randint(
        0, model.tokenizer.vocab_size, (1, max_seq_length)
    )
    example_attention_mask = torch.ones(1, max_seq_length, dtype=torch.long)

    print("Tracing model...")
    with torch.no_grad():
        traced_model = torch.jit.trace(
            wrapper, (example_input_ids, example_attention_mask), strict=False
        )

    inputs = [
        ct.TensorType(name="input_ids", shape=(1, max_seq_length), dtype=int),
        ct.TensorType(name="attention_mask", shape=(1, max_seq_length), dtype=int),
    ]

    outputs = [ct.TensorType(name="last_hidden_state", dtype=float)]

    print("Converting to CoreML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT32,
    )

    mlmodel.save(str(output_path))
    print(f"Model saved to {output_path}")

    # Download tokenizer alongside the mlpackage (not inside it, so Xcode
    # won't swallow it when compiling the CoreML model).
    tokenizer_dst = output_dir / "tokenizer.json"
    print("Downloading tokenizer.json...")
    urllib.request.urlretrieve(f"{hf_base}/tokenizer.json", tokenizer_dst)
    print(f"Downloaded tokenizer to {tokenizer_dst}")


if __name__ == "__main__":
    main()
