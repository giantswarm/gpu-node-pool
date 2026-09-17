#!/usr/bin/env python3
"""Assert the shape of a gpu-node-pool render on stdin: exactly a MachinePool, a
KubeadmConfig and a KarpenterMachinePool -- with `--prewarm` also the prewarm
PriorityClass and Job holding one GPU of the pool at negative priority -- no
Secret, no accelerator label, KubeadmConfig.discovery left to CABPK, the lib
volume with provisioned throughput and IOPS within gp3's ratio."""
import sys

import yaml

prewarm = "--prewarm" in sys.argv[1:]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
kinds = sorted(d["kind"] for d in docs)
expected = ["KarpenterMachinePool", "KubeadmConfig", "MachinePool"] + (["Job", "PriorityClass"] if prewarm else [])
assert kinds == sorted(expected), kinds
by_kind = {d["kind"]: d for d in docs}
for d in docs:
    assert "accelerator" not in yaml.safe_dump(d["metadata"]), d["metadata"]
kc = by_kind["KubeadmConfig"]
assert "discovery" not in kc["spec"]["joinConfiguration"], "discovery is CABPK's"
labels = next(a["value"] for a in kc["spec"]["joinConfiguration"]["nodeRegistration"]["kubeletExtraArgs"] if a["name"] == "node-labels")
assert "accelerator" not in labels, labels
assert any(t["key"] == "nvidia.com/gpu" and t["effect"] == "NoSchedule" for t in kc["spec"]["joinConfiguration"]["nodeRegistration"]["taints"])

kmp = by_kind["KarpenterMachinePool"]
pool = kmp["metadata"]["name"]
lib = next(m["ebs"] for m in kmp["spec"]["ec2NodeClass"]["blockDeviceMappings"] if m["deviceName"] == "/dev/xvdd")
assert isinstance(lib["throughput"], int) and isinstance(lib["iops"], int), lib
assert lib["throughput"] * 4 <= lib["iops"], f"gp3 allows 0.25 MiB/s per IOPS: {lib}"

if prewarm:
    pc, job = by_kind["PriorityClass"], by_kind["Job"]
    assert pc["metadata"]["name"] == f"{pool}-prewarm", pc["metadata"]
    assert pc["value"] < 0 and pc["preemptionPolicy"] == "Never" and pc["globalDefault"] is False, pc
    spec, pod = job["spec"], job["spec"]["template"]["spec"]
    assert job["metadata"]["name"] == pc["metadata"]["name"], job["metadata"]
    assert spec["backoffLimit"] == 0 and spec["ttlSecondsAfterFinished"] > 0 and spec["activeDeadlineSeconds"] > 0, spec
    assert pod["restartPolicy"] == "Never" and pod["terminationGracePeriodSeconds"] == 0, pod
    assert pod["priorityClassName"] == pc["metadata"]["name"], pod["priorityClassName"]
    assert pod["nodeSelector"] == {"giantswarm.io/machine-pool": pool}, pod["nodeSelector"]
    assert any(t["key"] == "nvidia.com/gpu" and t["operator"] == "Exists" and t["effect"] == "NoSchedule" for t in pod["tolerations"]), pod["tolerations"]
    (container,) = pod["containers"]
    resources = container["resources"]
    assert resources["requests"]["nvidia.com/gpu"] == "1" and resources["limits"]["nvidia.com/gpu"] == "1", resources
print(f"render ok: {', '.join(kinds)}")
