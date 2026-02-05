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
    def __init__(self, st_model):
        super().__init__()
        self.transformer = st_model[0].auto_model

    def forward(self, input_ids, attention_mask):
        outputs = self.transformer(input_ids=input_ids, attention_mask=attention_mask)
        token_embeddings = outputs.last_hidden_state
        # Mean pooling
        input_mask_expanded = (
            attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
        )
        sum_embeddings = torch.sum(token_embeddings * input_mask_expanded, dim=1)
        sum_mask = torch.clamp(input_mask_expanded.sum(dim=1), min=1e-9)
        embeddings = sum_embeddings / sum_mask
        # Normalize
        embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
        return embeddings


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

    # Derive output name from model path
    if args.output:
        output_path = Path(args.output)
    else:
        output_name = model_name.replace("/", "_").replace("-", "_") + ".mlpackage"
        output_path = Path(output_name)

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

    outputs = [ct.TensorType(name="embeddings", dtype=float)]

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

    # Download tokenizer into the mlpackage
    tokenizer_dst = output_path / "tokenizer.json"
    print("Downloading tokenizer.json...")
    urllib.request.urlretrieve(f"{hf_base}/tokenizer.json", tokenizer_dst)
    print(f"Downloaded tokenizer to {tokenizer_dst}")


if __name__ == "__main__":
    main()
