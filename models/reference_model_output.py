#! /usr/bin/env python3
"""
Reference implementation test for sentence embedding models.
Compares similarity scores against a query using SentenceTransformers.

Install dependencies:
    pip install -r requirements.txt

The first run will download the model.
"""

import argparse
from sentence_transformers import SentenceTransformer
from sentence_transformers.util import cos_sim


def main(model_name: str):
    print(f"Loading model: {model_name}")
    model = SentenceTransformer(model_name, device="cpu")

    cases = [
        (
            "Eating food",
            [
                "We ate hot dogs",
                "My parents took me to dinner",
                "I woke up",
            ],
        ),
        ("royalty", ["peasant", "queen"]),
    ]
    for query, candidates in cases:
        all_sentences = [query] + candidates
        embeddings = model.encode(all_sentences)

        query_embedding = embeddings[0]

        print(f'\nQuery: "{query}"\n')
        for i, sentence in enumerate(candidates):
            sim = cos_sim(query_embedding, embeddings[i + 1]).item()
            print(f'  {sim * 100:6.2f}%  "{sentence}"')

        # Also print the raw token IDs so you can cross-check against your Zig tokenizer
        print("\n--- Token ID cross-check ---")
        tokenizer = model.tokenizer
        for sentence in all_sentences:
            tokens = tokenizer.encode(sentence)
            print(f'  "{sentence}" -> {tokens}')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Get reference output for a model")
    parser.add_argument(
        "model_name",
        help=(
            "Huggingface name of model. "
            "e.g. `sentence-transformers/all-mpnet-base-v2`"
        ),
    )
    args = parser.parse_args()
    main(args.model_name)
