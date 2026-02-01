# Models
This directory contains helper scripts for dealing with ML/AI models. Although not checked into
source control, this is where models should be stored after conversion.

## Scripts
This directory contains the following helper scripts:
- `coreml-info.py` - this extracts the information about a CoreML model.
- `reference-model-output.py` - this runs a model over sample inputs to get expected outputs for
reference.
- `convert-to-coreml.py` - this converts a model from whatever its source is to the CoreML format.

To run these helper scripts, make sure you are using Python 3.12 or lower. And run
```bash
python3 -m venv venv
. ./venv/bin/activate
pip install -r requirement.txt
```
