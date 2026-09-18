#!/usr/bin/env python3
"""Assert the shape of a gpu-node-pool render on stdin: exactly a MachinePool, a
KubeadmConfig and a KarpenterMachinePool -- with `--prewarm <class>` also the prewarm
Job holding one GPU of the pool under the PriorityClass of that name -- every object
in the release namespace and nothing cluster-scoped (a pool release is delivered as
the organisation's tenant account, whose rights end at the namespace), no Secret, no
accelerator label, KubeadmConfig.discovery left to CABPK, the lib volume with
provisioned throughput and IOPS within gp3's ratio."""
import argparse

import yaml

args = argparse.ArgumentParser(description=__doc__)
args.add_argument("--namespace", required=True, help="the release namespace every object must be in")
args.add_argument("--prewarm", metavar="CLASS", help="expect the prewarm Job under this PriorityClass")
opts = args.parse_args()

docs = [d for d in yaml.safe_load_all(__import__("sys").stdin) if d]
kinds = sorted(d["kind"] for d in docs)
expected = ["KarpenterMachinePool", "KubeadmConfig", "MachinePool"] + (["Job"] if opts.prewarm else [])
assert kinds == sorted(expected), kinds
by_kind = {d["kind"]: d for d in docs}
for d in docs:
    assert d["metadata"].get("namespace") == opts.namespace, f"{d['kind']} {d['metadata']['name']} is not in namespace {opts.namespace}: cluster-scoped or unnamespaced"
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

if opts.prewarm:
    job = by_kind["Job"]
    spec, pod = job["spec"], job["spec"]["template"]["spec"]
    assert job["metadata"]["name"] == f"{pool}-prewarm", job["metadata"]
    assert spec["backoffLimit"] == 0 and spec["ttlSecondsAfterFinished"] > 0 and spec["activeDeadlineSeconds"] > 0, spec
    assert pod["restartPolicy"] == "Never" and pod["terminationGracePeriodSeconds"] == 0, pod
    assert pod["priorityClassName"] == opts.prewarm, pod["priorityClassName"]
    assert pod["nodeSelector"] == {"giantswarm.io/machine-pool": pool}, pod["nodeSelector"]
    assert any(t["key"] == "nvidia.com/gpu" and t["operator"] == "Exists" and t["effect"] == "NoSchedule" for t in pod["tolerations"]), pod["tolerations"]
    (container,) = pod["containers"]
    resources = container["resources"]
    assert resources["requests"]["nvidia.com/gpu"] == "1" and resources["limits"]["nvidia.com/gpu"] == "1", resources
print(f"render ok: {', '.join(kinds)} in {opts.namespace}")
