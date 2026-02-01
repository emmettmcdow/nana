#! /usr/bin/env python3
"""This script will give info about a particular CoreML package. Navigate to directory which
contains the `float32_model.mlpackage` file and run this."""
import coremltools as ct

# TODO: generalize this to handle different models
model = ct.models.MLModel("float32_model.mlpackage")
spec = model.get_spec()
print(spec.description)
