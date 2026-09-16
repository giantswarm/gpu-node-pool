#!/usr/bin/env python3
"""Diff a node pool's bootstrap between two helm renders as the node sees it.

Usage: bootstrap_diff.py <oracle-render.yaml> <our-render.yaml> <pool> <whitelist.yaml>

From each render the pool's MachinePool, KubeadmConfig and KarpenterMachinePool
are taken (label giantswarm.io/machine-pool=<pool>), every file's content is
resolved inline (base64 decoded, contentFrom.secret resolved from Secrets of the
same render where present), the Ignition config's additionalConfig is decoded
from its YAML string, trailing whitespace is normalized, the whitelisted paths
are removed from both, and what remains must be identical.

A whitelist entry is `<Kind> <dotted.path>`. A path segment may select elements
of a list instead of removing the whole list: `files[path=/etc/x]` removes the
mappings whose `path` is `/etc/x`, `preKubeadmCommands[=systemctl start x]`
removes the scalar equal to the text after `=`. A selector in the middle of a
path descends into the one matching element, so a unit added inside the
Ignition config is `... additionalConfig.systemd.units[name=x.service]`.
"""
import base64
import difflib
import re
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
        clc = d.get("spec", {}).get("ignition", {}).get("containerLinuxConfig", {})
        if isinstance(clc.get("additionalConfig"), str):
            clc["additionalConfig"] = yaml.safe_load(clc["additionalConfig"])
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


SEGMENT = re.compile(r"^([^\[]*)(?:\[([^\]=]*)=([^\]]*)\])?$")


def segment(text):
    """A path segment as (key, selector); the selector is None or (field, value),
    an empty field selecting a scalar list element equal to the value."""
    key, field, value = SEGMENT.match(text).groups()
    return key, (None if field is None else (field, value))


def selected(element, selector):
    field, value = selector
    if field == "":
        return isinstance(element, str) and element == value
    return isinstance(element, dict) and str(element.get(field)) == value


def remove(objs, kind, dotted):
    node = objs.get(kind)
    segments = re.split(r"\.(?![^\[]*\])", dotted)
    for text in segments[:-1]:
        key, selector = segment(text)
        node = node.get(key) if isinstance(node, dict) else None
        if selector is not None and isinstance(node, list):
            node = next((e for e in node if selected(e, selector)), None)
        if node is None:
            return
    key, selector = segment(segments[-1])
    if not isinstance(node, dict):
        return
    if selector is None:
        node.pop(key, None)
    elif isinstance(node.get(key), list):
        node[key] = [e for e in node[key] if not selected(e, selector)]


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
