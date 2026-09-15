#!/usr/bin/env python3
"""Assert the shape of a gpu-node-pool render on stdin: exactly a MachinePool, a
KubeadmConfig and a KarpenterMachinePool, no Secret, no accelerator label,
KubeadmConfig.discovery left to CABPK."""
import sys

import yaml

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
kinds = sorted(d["kind"] for d in docs)
assert kinds == ["KarpenterMachinePool", "KubeadmConfig", "MachinePool"], kinds
for d in docs:
    assert "accelerator" not in yaml.safe_dump(d["metadata"]), d["metadata"]
kc = next(d for d in docs if d["kind"] == "KubeadmConfig")
assert "discovery" not in kc["spec"]["joinConfiguration"], "discovery is CABPK's"
labels = next(a["value"] for a in kc["spec"]["joinConfiguration"]["nodeRegistration"]["kubeletExtraArgs"] if a["name"] == "node-labels")
assert "accelerator" not in labels, labels
assert any(t["key"] == "nvidia.com/gpu" and t["effect"] == "NoSchedule" for t in kc["spec"]["joinConfiguration"]["nodeRegistration"]["taints"])
print(f"render ok: {', '.join(kinds)}")
