#!/usr/bin/env python3
"""Validate every KarpenterMachinePool of a render against the CRD an installation serves.

Usage: check_crd.py <crd.yaml> < render.yaml

The storage version's openAPIV3Schema is applied as a JSON Schema, tightened the
way server-side apply treats the object: every declared object refuses fields the
CRD does not declare unless it preserves unknown fields. A field the CRD does not
know, a wrong type (`iops: "4000"`) or a value off its pattern or enum fails here
instead of on the installation. The CRD's CEL rules (x-kubernetes-validations) are
not evaluated.
"""
import sys

import yaml
from jsonschema import Draft4Validator


def strict(schema):
    """Refuse undeclared fields on every object schema that declares properties."""
    if isinstance(schema, dict):
        if "properties" in schema and "additionalProperties" not in schema and not schema.get("x-kubernetes-preserve-unknown-fields"):
            schema["additionalProperties"] = False
        for value in schema.values():
            strict(value)
    elif isinstance(schema, list):
        for value in schema:
            strict(value)
    return schema


crd = yaml.safe_load(open(sys.argv[1]))
kind = crd["spec"]["names"]["kind"]
version = next(v for v in crd["spec"]["versions"] if v["storage"])
validator = Draft4Validator(strict(version["schema"]["openAPIV3Schema"]))
objects = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] == kind]
assert objects, f"no {kind} in the render"
errors = [
    f"{o['metadata']['name']}: {'.'.join(str(p) for p in e.absolute_path) or '.'}: {e.message}"
    for o in objects
    for e in validator.iter_errors(o)
]
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"crd ok: {len(objects)} {kind} against {crd['metadata']['name']} {version['name']}")
