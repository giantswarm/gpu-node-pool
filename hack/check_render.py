#!/usr/bin/env python3
"""Assert the shape of a gpu-node-pool render on stdin: exactly a MachinePool, a
KubeadmConfig and a KarpenterMachinePool -- with `--prewarm <class>` also the prewarm
Job holding one GPU of the pool under the PriorityClass of that name -- every object
in the release namespace and nothing cluster-scoped (a pool release is delivered as
the organisation's tenant account, whose rights end at the namespace), no Secret, no
accelerator label, KubeadmConfig.discovery left to CABPK, containerd's locked-memory limit
unlimited (the `memlock.conf` drop-in: a container inherits the limit and has no CAP_IPC_LOCK, so
a runtime that mlock()s its weights dies under the 8 MB default), the Teleport join as the
cluster's own workers carry it (the join token from the cluster's `<cluster>-teleport-join-token`
Secret, /etc/teleport.yaml, the role script, teleport.service enabled) and -- with `--proxy` --
the http-proxy.conf drop-in of containerd, kubelet and teleport (none without it), the node's lib volume as
`--lib-source` names it (instance-store: the unit formatting the store, its script and
Karpenter's instanceStorePolicy, no lib filesystem entry and no lib block device mapping;
ebs: the lib volume on /dev/xvdd with provisioned throughput and IOPS within gp3's ratio,
no unit and no policy; either way var-lib.mount through the label), the NodePool template
requiring exactly the zones of `--zones` (none without it), the NodePool consolidating
as `--consolidation-policy` names it (default WhenEmpty: a node serving a model is never
replaced by a cheaper size), and the bootstrap of the driver
source named by `--nvidia-driver`: with flatcar-sysext the enabled-sysext line, nvidia.service
masked, the CDI unit ordered after the extension and -- with `--sysext-url` -- Ignition
downloading the extension image from that URL into the path the OS activates it from;
with image-build the build at boot and the CDI unit waiting for it."""
import argparse
import base64
import re

import yaml

args = argparse.ArgumentParser(description=__doc__)
args.add_argument("--namespace", required=True, help="the release namespace every object must be in")
args.add_argument("--prewarm", metavar="CLASS", help="expect the prewarm Job under this PriorityClass")
args.add_argument("--zones", metavar="ZONE[,ZONE]", help="expect the NodePool template to require these zones; without it, no zone requirement")
args.add_argument("--consolidation-policy", choices=["WhenEmpty", "WhenEmptyOrUnderutilized"], default="WhenEmpty", help="expect the NodePool to consolidate with this policy")
args.add_argument("--lib-source", choices=["instance-store", "ebs"], help="expect the node's lib volume from this source")
args.add_argument("--nvidia-driver", choices=["flatcar-sysext", "image-build"], help="expect the bootstrap of this driver source")
args.add_argument("--sysext-url", metavar="URL", help="with flatcar-sysext, expect Ignition to download the extension image from this URL; without it, no download")
args.add_argument("--proxy", action="store_true", help="expect the http-proxy drop-in of containerd, kubelet and teleport; without it, none")
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
files = {f["path"]: base64.b64decode(f["content"]).decode() for f in kc["spec"]["files"] if f.get("encoding") == "base64"}
ignition = yaml.safe_load(kc["spec"]["ignition"]["containerLinuxConfig"]["additionalConfig"])
units = {u["name"]: u for u in ignition["systemd"]["units"]}
dropins = {d["name"]: d["contents"] for d in units["containerd.service"]["dropins"]}
assert "Slice=kubereserved.slice" in dropins["10-change-cgroup.conf"], dropins
assert "LimitMEMLOCK=infinity" in dropins["memlock.conf"], f"a GPU node's containerd lets a workload lock its memory: {dropins}"

kmp = by_kind["KarpenterMachinePool"]
pool = kmp["metadata"]["name"]
ec2 = kmp["spec"]["ec2NodeClass"]
mappings = {m["deviceName"]: m for m in ec2["blockDeviceMappings"]}
assert mappings["/dev/xvda"].get("rootVolume") and "/dev/xvde" in mappings, mappings.keys()

# The Teleport join, as the cluster's own workers carry it and the only way the nodes join.
paths = {f["path"] for f in kc["spec"]["files"]}
(token,) = [f for f in kc["spec"]["files"] if f["path"] == "/etc/teleport-join-token"]
cluster = token["contentFrom"]["secret"]["name"].removesuffix("-teleport-join-token")
assert cluster and pool.startswith(f"{cluster}-") and token["contentFrom"]["secret"]["key"] == "joinToken", token
assert {"/etc/teleport.yaml", "/opt/teleport-node-role.sh"} <= paths, paths
assert units["teleport.service"]["enabled"] and "--config=/etc/teleport.yaml" in units["teleport.service"]["contents"], units.get("teleport.service")
proxied = {path for path in paths if path.endswith("/http-proxy.conf")}
assert proxied == ({f"/etc/systemd/system/{unit}.service.d/http-proxy.conf" for unit in ("containerd", "kubelet", "teleport")} if opts.proxy else set()), proxied
if opts.lib_source:
    filesystems = {f["name"]: f["mount"] for f in ignition["storage"]["filesystems"]}
    assert "What=/dev/disk/by-label/lib" in units["var-lib.mount"]["contents"] and units["var-lib.mount"]["enabled"], units["var-lib.mount"]
    assert filesystems["log"]["device"] == "/dev/xvde", filesystems
    if opts.lib_source == "instance-store":
        assert "/dev/xvdd" not in mappings and ec2.get("instanceStorePolicy") == "RAID0", (mappings.keys(), ec2.get("instanceStorePolicy"))
        assert "lib" not in filesystems, filesystems
        assert units["format-instance-store.service"] == {"name": "format-instance-store.service", "enabled": True}, units.get("format-instance-store.service")
        unit = files["/etc/systemd/system/format-instance-store.service"]
        for line in ("DefaultDependencies=no", "Before=var-lib.mount local-fs.target", "RequiredBy=var-lib.mount local-fs.target", "ExecStart=/opt/bin/format-instance-store.sh"):
            assert line in unit, (line, unit)
        script = files["/opt/bin/format-instance-store.sh"]
        for step in ("Amazon EC2 NVMe Instance Storage", "mkfs.xfs -f -L lib", "exit 1"):
            assert step in script, (step, script)
    else:
        lib = mappings["/dev/xvdd"]["ebs"]
        assert isinstance(lib["throughput"], int) and isinstance(lib["iops"], int), lib
        assert lib["throughput"] * 4 <= lib["iops"], f"gp3 allows 0.25 MiB/s per IOPS: {lib}"
        assert "instanceStorePolicy" not in ec2, ec2["instanceStorePolicy"]
        assert filesystems["lib"] == {"device": "/dev/xvdd", "format": "xfs", "wipeFilesystem": True, "label": "lib"}, filesystems.get("lib")
        assert "format-instance-store.service" not in units and not any("format-instance-store" in path for path in files), (units.keys(), files.keys())
disruption = kmp["spec"]["nodePool"]["disruption"]
assert disruption == {"consolidationPolicy": opts.consolidation_policy, "consolidateAfter": "10m"}, f"the pool consolidates with {opts.consolidation_policy}: {disruption}"
requirements = {r["key"]: r for r in kmp["spec"]["nodePool"]["template"]["spec"]["requirements"]}
zone = requirements.get("topology.kubernetes.io/zone")
if opts.zones:
    assert zone == {"key": "topology.kubernetes.io/zone", "operator": "In", "values": opts.zones.split(",")}, zone
else:
    assert zone is None, f"an empty pool.zones renders no zone requirement: {zone}"

if opts.nvidia_driver:
    downloads = ignition.get("storage", {}).get("files", [])
    cdi = files["/etc/systemd/system/nvidia-cdi-spec.service"]
    if opts.nvidia_driver == "flatcar-sysext":
        name = files["/etc/flatcar/enabled-sysext.conf"].rstrip("\n")
        assert re.fullmatch(r"nvidia-drivers-[0-9]{3}(-open)?", name), files["/etc/flatcar/enabled-sysext.conf"]
        assert units["nvidia.service"] == {"name": "nvidia.service", "enabled": False, "mask": True}, units.get("nvidia.service")
        assert "Requires=nvidia.service" not in cdi and "After=nvidia.service" not in cdi and "After=systemd-sysext.service" in cdi, cdi
        for step in ("modprobe -a nvidia nvidia_uvm nvidia_modeset", "create-device-nodes --control-devices", "nvidia-smi -L", "nvidia-container-runtime.mode=cdi", "cdi generate"):
            assert step in cdi, (step, cdi)
        if opts.sysext_url:
            (download,) = downloads
            assert re.fullmatch(rf"/etc/flatcar/sysext/flatcar-{name}-[0-9]+\.[0-9]+\.[0-9]+\.raw", download["path"]), download
            assert download["contents"]["remote"]["url"] == opts.sysext_url and download["mode"] == 0o644, download
        else:
            assert not downloads, downloads
    else:
        assert "/etc/flatcar/enabled-sysext.conf" not in files and "nvidia.service" not in units and not downloads, (units.keys(), downloads)
        assert "Requires=nvidia.service" in cdi and "After=nvidia.service" in cdi, cdi

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
