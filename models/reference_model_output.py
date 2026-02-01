#! /usr/bin/env python3
"""
Reference implementation test for jina-embeddings-v2-base-en.
Compares similarity scores against a query using the canonical
Hugging Face + mean pooling pipeline.

Install dependencies:
    pip install -r requirements.txt

The first run will download the model (~500MB).
"""
# TODO: generalize this to handle different models

import torch
import torch.nn.functional as F
from transformers import AutoTokenizer, AutoModel


def mean_pooling(model_output, attention_mask):
    token_embeddings = model_output[0]  # last_hidden_state
    input_mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
    sum_embeddings = torch.sum(token_embeddings * input_mask_expanded, 1)
    sum_mask = torch.clamp(input_mask_expanded.sum(1), min=1e-9)
    return sum_embeddings / sum_mask


def embed(model, tokenizer, sentences):
    encoded = tokenizer(sentences, padding=True, truncation=True, max_length=128, return_tensors="pt")
    with torch.no_grad():
        outputs = model(**encoded)
    embeddings = mean_pooling(outputs, encoded["attention_mask"])
    embeddings = F.normalize(embeddings, p=2, dim=1)
    return embeddings


def cosine_similarity(a, b):
    # Both vectors are already L2-normalized, so dot product == cosine similarity
    return torch.dot(a, b).item()


def main():
    model_name = "jinaai/jina-embeddings-v2-base-en"
    print(f"Loading model: {model_name}")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    model = AutoModel.from_pretrained(model_name)
    model.eval()

    query = "Eating food"
    candidates = [
        "We ate hot dogs",
        "My parents took me to dinner",
        "I woke up",
    ]

    all_sentences = [query] + candidates
    embeddings = embed(model, tokenizer, all_sentences)

    query_embedding = embeddings[0]
    candidate_embeddings = embeddings[1:]

    print(f"\nQuery: \"{query}\"\n")
    for sentence, candidate_emb in zip(candidates, candidate_embeddings):
        sim = cosine_similarity(query_embedding, candidate_emb)
        print(f"  {sim * 100:6.2f}%  \"{sentence}\"")

    # Also print the raw token IDs so you can cross-check against your Zig tokenizer
    print("\n--- Token ID cross-check ---")
    for sentence in all_sentences:
        tokens = tokenizer.encode(sentence)
        print(f"  \"{sentence}\" -> {tokens}")


if __name__ == "__main__":
    main()
