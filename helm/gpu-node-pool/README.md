# gpu-node-pool

A GPU node pool as its own Cluster API release for an existing Giant Swarm cluster — MachinePool, KubeadmConfig and KarpenterMachinePool with their own worker bootstrap.

**Homepage:** <https://github.com/giantswarm/gpu-node-pool>

## Source Code

* <https://github.com/giantswarm/gpu-node-pool>

## What the chart renders

For an existing Cluster API cluster named in its values the chart renders exactly three objects
in the release's namespace (`org-<organization>`) and no Secret of its own:

- a **`MachinePool`** `<cluster>-<pool>` with `version` the pool's own Kubernetes version,
- a **`KubeadmConfig`** `<cluster>-<pool>-<hash>` carrying the worker bootstrap of a CAPA Flatcar
  Karpenter worker with every file inline; the hash covers the whole spec, so a bootstrap change
  renames the object and rolls the nodes,
- a **`KarpenterMachinePool`** `<cluster>-<pool>` with the GPU shape: the instance family of the
  chosen accelerator, the `nvidia.com/gpu` `NoSchedule` taint, consolidation down to zero nodes.

The nodes carry the label `giantswarm.io/machine-pool=<cluster>-<pool>`; the accelerator is read
from gpu-feature-discovery's `nvidia.com/gpu.product`. The only object referenced by name outside
the release is the cluster's `<cluster>-teleport-join-token` Secret, behind `teleport.enabled`.
Nothing references an object the cluster's release renames on upgrade.

## Values contract

| Block | What it is | Who sets it |
|---|---|---|
| `cluster.name`, `cluster.organization` | the existing cluster | the person, through cluster-manager |
| `pool.name` | `^[a-z0-9][-a-z0-9]{3,18}[a-z0-9]$` — five to twenty characters, `gpu00` or `gpu-l4`, not `gpu`; `<cluster>-<pool>` becomes the NodePool, EC2NodeClass and S3 key | the person |
| `pool.accelerator`, `pool.sizes` | one of the curated list (`nvidia-l4` → `g6`, `nvidia-a10g` → `g5`, `nvidia-t4` → `g4dn`, `nvidia-l40s` → `g6e`) and the instance sizes Karpenter may pick | the person |
| `pool.minSize`, `pool.maxSize` | `0` — Karpenter scales the pool to zero — and the Karpenter `limits` bounding it (`nvidia.com/gpu`, `cpu`, `memory`) | the person |
| `pool.kubernetesVersion`, `pool.machineImage` | the pool's own pins | cluster-manager, from the cluster's Release CR at creation |
| `teleport.enabled` | join the nodes to Teleport | cluster-manager, from the presence of `<cluster>-teleport-join-token` |
| `cluster.baseDomain`, `cluster.managementCluster`, `cluster.containerRegistry`, `cluster.registryMirrors`, `cluster.proxy`, `cluster.cilium.ipamMode`, `cluster.kubelet.maxPods` | the snapshot of the cluster's settings the bootstrap needs | cluster-manager, from the cluster's values and `AWSCluster` at creation; refreshed by a re-run |

**Credentials never go into `spec.values`.** Where a cluster has registry credentials, the
release receives them through a `valuesFrom` Secret beside the HelmRelease; the chart reads them
as ordinary values from either source.

## The image contract: what the image provides, what the pool configures

The nodes run the Giant Swarm Flatcar image (`flatcar-<channel>-<flatcar>-kube-<k8s>-tooling-<tooling>-gs`,
built by capi-image-builder). For GPUs it provides:

- the **NVIDIA driver**: Flatcar's `nvidia.service` (`setup-nvidia`) builds the driver for the running
  kernel at boot and merges it into `/usr` as a system extension — kernel modules, `libcuda.so`,
  `libnvidia-ml.so` and friends under `/usr/lib64`, `nvidia-smi` and the other driver binaries under
  `/opt/bin` with symlinks in `/usr/bin`;
- the **NVIDIA container toolkit** as the `nvidia-runtime` system extension: `nvidia-container-runtime`,
  `nvidia-ctk`, `nvidia-cdi-hook` in `/usr/bin`, its configuration in `/etc/nvidia-container-runtime/config.toml`
  (`mode = "auto"`), its `nvidia-cdi-refresh` units present but not enabled;
- **containerd** with the `nvidia` runtime handler (`BinaryName /usr/bin/nvidia-container-runtime`, `runc`
  stays the default) and CDI on (`enable_cdi`, spec dirs `/etc/cdi` and `/var/run/cdi`).

The pool's bootstrap adds one unit, `nvidia-cdi-spec.service`, ordered after `nvidia.service`: it sets the
runtime to `mode = "cdi"` and writes the CDI specification of the driver to `/var/run/cdi/nvidia.yaml`
(`nvidia-ctk cdi generate`) with `/usr/bin` ahead of `/opt/bin` on its PATH. In `auto` mode the runtime
generates that specification per container instead, locating the driver's binaries through containerd's
PATH, which puts `/opt/bin` first on this image; `nvidia-smi` then lands at `/opt/bin/nvidia-smi` inside
the container, off every container's PATH, and the GPU operator's toolkit validation
(`nvidia-smi` under RuntimeClass `nvidia`) never passes. With the specification written once, the
runtime injects exactly what it says, `nvidia-smi` at `/usr/bin/nvidia-smi` included.

The GPU operator runs on the `flatcar` row of cluster-manager's table: `driver.enabled=false`,
`toolkit.enabled=false`, operands under RuntimeClass `nvidia`, `cdi.enabled=true`. Its operands get every
GPU through the runtime (`NVIDIA_VISIBLE_DEVICES=all` → `nvidia.com/gpu=all` from the specification);
workloads requesting `nvidia.com/gpu` get theirs through the device plugin's CDI devices, which containerd
injects natively. A node is a GPU node once `nvidia.com/gpu` is allocatable and the ClusterPolicy is
`ready`; no step on the node is left to a person.

## The skew rule

The pool pins its own Kubernetes version and machine image. A cluster upgrade never touches
them; they move only when the pool's values move. A pool is never newer than the control plane —
cluster-manager refuses it, and the `KarpenterMachinePool` controller's version-skew check blocks
it anyway. How far a pool may lag is the Kubernetes skew policy.

## Deletion with the cluster

Cluster API owns the `MachinePool` through the `Cluster` and deletes it — with its
`KubeadmConfig` and `KarpenterMachinePool` — when the cluster is deleted; the
`KarpenterMachinePool` finalizer waits for zero instances. The pool's HelmRelease and
OCIRepository: **in apply mode** they carry an ownerReference to the `Cluster`, so garbage
collection removes them and helm-controller uninstalls on the way; **in commit mode** the files
carry no ownerReference (a Cluster UID never goes into git) and deletion with the cluster is the
person's live step.

## Pinning the chart

Pin the chart version exactly in the HelmRelease. A bootstrap change rolls GPU nodes under a
served model; bumps are meant to be explicit.

## Guarding the bootstrap

`make verify` renders the fixture cluster (`ci/ci-values.yaml`, which `ct lint` uses as well) for every accelerator with and without
teleport, compares the goldens, and diffs the bootstrap — as the node sees it, files resolved —
against the newest released cluster-aws, pinned in `hack/oracle/Chart.yaml` and bumped by
Renovate. The intentional differences are the one list in `hack/oracle/whitelist.yaml`; any other
difference fails CI, so a cluster-aws bump that changes the worker bootstrap fails until the chart
follows. `make goldens` rewrites the goldens.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster.name | string | `""` | Name of the existing Cluster API cluster the pool joins. |
| cluster.organization | string | `""` | Organization owning the cluster; the release lives in `org-<organization>`. |
| cluster.baseDomain | string | `""` | Base domain of the installation (the cluster's `global.connectivity.baseDomain`). |
| cluster.managementCluster | string | `""` | Name of the management cluster (the cluster's `global.managementCluster`). |
| cluster.containerRegistry | string | `"gsoci.azurecr.io"` | Registry containerd pulls the sandbox (pause) image from. |
| cluster.registryMirrors | object | `{}` | Registry mirrors as containerd `hosts.toml` files: registry host -> ordered list of endpoint hosts (a snapshot of the cluster's mirrors and local registry cache). |
| cluster.proxy.enabled | bool | `false` | Route containerd, kubelet, teleport and the kubeadm commands through the cluster's HTTP proxy. |
| cluster.proxy.httpProxy | string | `""` | HTTP proxy URL. |
| cluster.proxy.httpsProxy | string | `""` | HTTPS proxy URL. |
| cluster.proxy.noProxy | string | `""` | Comma-separated no-proxy list as the cluster computes it. |
| cluster.cilium.ipamMode | string | `"kubernetes"` | Cilium IPAM mode of the cluster; decides the unmanaged-devices network unit. |
| cluster.kubelet.maxPods | int | `110` | Maximum pods per node as the cluster's kubelet patch sets it. |
| pool.name | string | `""` | Name of the node pool within the cluster; five to twenty characters. |
| pool.kubernetesVersion | string | `""` | Kubernetes version the pool's nodes run (`1.33.1`), never newer than the control plane. |
| pool.machineImage | string | `""` | Name of the Flatcar machine image (`flatcar-<channel>-<flatcar>-kube-<k8s>-tooling-<tooling>-gs`). |
| pool.accelerator | string | `"nvidia-l4"` | Accelerator from the curated list; picks the EC2 instance family. |
| pool.sizes | list | `["xlarge","2xlarge","4xlarge"]` | Instance sizes Karpenter may pick within the accelerator's family, smallest first. |
| pool.minSize | int | `0` | Minimum size; Karpenter scales the pool to zero when nothing is scheduled. |
| pool.maxSize | object | `{"nvidia.com/gpu":"4"}` | Upper bound of the pool, as Karpenter limits (resources across all of its nodes). |
| pool.consolidateAfter | string | `"10m"` | Time an empty or underutilized node lives before Karpenter consolidates it. |
| pool.volumes.root | string | `"15Gi"` | Root volume. |
| pool.volumes.lib | string | `"200Gi"` | `/var/lib` volume (container images, kubelet). |
| pool.volumes.log | string | `"30Gi"` | `/var/log` volume. |
| teleport.enabled | bool | `true` | Join the nodes to Teleport with the cluster's `<cluster>-teleport-join-token` Secret; off where the cluster has none. |
