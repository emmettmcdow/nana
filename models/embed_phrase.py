#!/usr/bin/env python3
"""
Emit the embedding vector for a single phrase using SentenceTransformers.

Usage:
    models/venv/bin/python models/embed_phrase.py <model_name> <phrase>

Prints one float per line to stdout (768 lines for mpnet).
All diagnostic output goes to stderr.
"""

import argparse
import sys

from sentence_transformers import SentenceTransformer


def main():
    parser = argparse.ArgumentParser(
        description="Embed a single phrase and print the vector to stdout."
    )
    parser.add_argument(
        "model_name",
        help="HuggingFace model name, e.g. sentence-transformers/all-mpnet-base-v2",
    )
    parser.add_argument("phrase", help="The phrase to embed")
    args = parser.parse_args()

    print(f"Loading model: {args.model_name}", file=sys.stderr)
    model = SentenceTransformer(args.model_name, device="cpu")

    embedding = model.encode(args.phrase)

    for val in embedding:
        print(f"{val:.15e}")


if __name__ == "__main__":
    main()
