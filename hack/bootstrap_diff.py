#!/usr/bin/env python3
"""Diff a node pool's bootstrap between two helm renders as the node sees it.

Usage: bootstrap_diff.py <oracle-render.yaml> <our-render.yaml> <pool> <whitelist.yaml>

From each render the pool's MachinePool, KubeadmConfig and KarpenterMachinePool
are taken (label giantswarm.io/machine-pool=<pool>), every file's content is
resolved inline (base64 decoded, contentFrom.secret resolved from Secrets of the
same render where present), trailing whitespace is normalized, the whitelisted
paths are removed from both, and what remains must be identical.
"""
import base64
import difflib
import sys

import yaml

KINDS = ("KarpenterMachinePool", "KubeadmConfig", "MachinePool")


def load(path, pool):
    docs = [d for d in yaml.safe_load_all(open(path)) if d]
    secrets = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Secret"}
    out = {}
    for d in docs:
        if d.get("kind") not in KINDS:
            continue
        if d["metadata"].get("labels", {}).get("giantswarm.io/machine-pool") != pool:
            continue
        for f in d.get("spec", {}).get("files", []) or []:
            ref = f.get("contentFrom", {}).get("secret")
            if ref and ref["name"] in secrets:
                s = secrets[ref["name"]]
                f["content"] = (s.get("stringData") or {}).get(ref["key"]) or base64.b64decode(s["data"][ref["key"]]).decode()
                f["encoding"] = "plain"
                del f["contentFrom"]
            elif f.get("encoding") == "base64":
                f["content"] = base64.b64decode(f["content"]).decode()
                f["encoding"] = "plain"
        out[d["kind"]] = normalize(d)
    return out


def normalize(node):
    if isinstance(node, dict):
        return {k: normalize(v) for k, v in node.items()}
    if isinstance(node, list):
        return [normalize(v) for v in node]
    if isinstance(node, str) and "\n" in node:
        return "\n".join(line.rstrip() for line in node.rstrip().splitlines())
    return node


def remove(objs, kind, dotted):
    node = objs.get(kind)
    keys = dotted.split(".")
    for k in keys[:-1]:
        node = node.get(k) if isinstance(node, dict) else None
        if node is None:
            return
    if isinstance(node, dict):
        node.pop(keys[-1], None)


def main():
    oracle_path, ours_path, pool, whitelist_path = sys.argv[1:5]
    oracle, ours = load(oracle_path, pool), load(ours_path, pool)
    missing = [k for k in KINDS if k not in ours or k not in oracle]
    if missing:
        sys.exit(f"missing in one render: {missing}")
    for entry in yaml.safe_load(open(whitelist_path)):
        kind, dotted = entry.split(" ", 1)
        remove(oracle, kind, dotted)
        remove(ours, kind, dotted)
    a = yaml.safe_dump(oracle, sort_keys=True, width=1000).splitlines()
    b = yaml.safe_dump(ours, sort_keys=True, width=1000).splitlines()
    diff = list(difflib.unified_diff(a, b, "cluster-aws", "gpu-node-pool", lineterm="", n=2))
    if diff:
        print("\n".join(diff))
        sys.exit("bootstrap differs from cluster-aws beyond the whitelist")
    print(f"bootstrap identical to cluster-aws beyond {whitelist_path}")


if __name__ == "__main__":
    main()
