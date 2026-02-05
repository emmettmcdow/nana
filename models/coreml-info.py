#! /usr/bin/env python3
"""This script will give info about a particular CoreML package."""

import argparse
import coremltools as ct

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Get info about a CoreML model")
    parser.add_argument("path", help="Path to the .mlpackage or .mlmodel file")
    args = parser.parse_args()

    model = ct.models.MLModel(args.path)
    spec = model.get_spec()
    print(spec.description)
