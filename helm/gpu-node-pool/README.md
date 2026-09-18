# gpu-node-pool

A GPU node pool as its own Cluster API release for an existing Giant Swarm cluster — MachinePool, KubeadmConfig and KarpenterMachinePool with their own worker bootstrap.

**Homepage:** <https://github.com/giantswarm/gpu-node-pool>

## Source Code

* <https://github.com/giantswarm/gpu-node-pool>

## What the chart renders

For an existing Cluster API cluster named in its values the chart renders three objects in the
release's namespace (`org-<organization>`) and no Secret of its own — with `pool.prewarm.enabled`
also the [prewarm](#prewarming-the-first-node) Job. Every object is namespaced: a pool release
is delivered as the organisation's tenant ServiceAccount, whose rights end at the release
namespace, so the chart renders nothing cluster-scoped.

- a **`MachinePool`** `<cluster>-<pool>` with `version` the pool's own Kubernetes version,
- a **`KubeadmConfig`** `<cluster>-<pool>-<hash>` carrying the worker bootstrap of a CAPA Flatcar
  Karpenter worker with every file inline; the hash covers the whole spec, so a bootstrap change
  renames the object and rolls the nodes,
- a **`KarpenterMachinePool`** `<cluster>-<pool>` with the GPU shape: the instance family of the
  chosen accelerator, the `nvidia.com/gpu` `NoSchedule` taint, consolidation down to zero nodes
  and, with `pool.zones`, a [zone requirement](#pinning-the-pool-to-zones).

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
| `pool.zones` | the availability zones the nodes launch in, [pinning the pool](#pinning-the-pool-to-zones) to a zonal volume it serves; empty for any zone of the cluster's node subnets | the person; cluster-manager, from the installation's kept model cache claim |
| `pool.minSize`, `pool.maxSize` | `0` — Karpenter scales the pool to zero — and the Karpenter `limits` bounding it (`nvidia.com/gpu`, `cpu`, `memory`) | the person |
| `pool.volumes.root`, `pool.volumes.lib`, `pool.volumes.log`, `pool.volumes.libThroughput`, `pool.volumes.libIops` | the node's gp3 volumes and the [provisioned performance of the lib volume](#the-lib-volume) | the person; the defaults fit a serving node |
| `pool.nvidiaDriver` | the source of the node's NVIDIA driver — Flatcar's prebuilt, release-matched extension by default, or the build at boot — its branch and a mirror for the extension image ([the image contract](#the-image-contract-what-the-image-provides-what-the-pool-configures)) | the person; the defaults fit every image since Flatcar 4344.0.0 |
| `pool.prewarm` | [launch the first node at install](#prewarming-the-first-node) with a preemptible placeholder Job under the platform's PriorityClass (`pool.prewarm.priorityClassName`); the installation's own pool only | the person, through cluster-manager |
| `pool.kubernetesVersion`, `pool.machineImage` | the pool's own pins | cluster-manager, from the cluster's Release CR at creation |
| `teleport.enabled` | join the nodes to Teleport | cluster-manager, from the presence of `<cluster>-teleport-join-token` |
| `cluster.baseDomain`, `cluster.managementCluster`, `cluster.containerRegistry`, `cluster.registryMirrors`, `cluster.proxy`, `cluster.cilium.ipamMode`, `cluster.kubelet.maxPods` | the snapshot of the cluster's settings the bootstrap needs | cluster-manager, from the cluster's values and `AWSCluster` at creation; refreshed by a re-run |

**Credentials never go into `spec.values`.** Where a cluster has registry credentials, the
release receives them through a `valuesFrom` Secret beside the HelmRelease; the chart reads them
as ordinary values from either source.

## The image contract: what the image provides, what the pool configures

The nodes run the Giant Swarm Flatcar image (`flatcar-<channel>-<flatcar>-kube-<k8s>-tooling-<tooling>-gs`,
built by capi-image-builder). For GPUs it provides:

- the **NVIDIA container toolkit** as the `nvidia-runtime` system extension: `nvidia-container-runtime`,
  `nvidia-ctk`, `nvidia-cdi-hook` in `/usr/bin`, its configuration in `/etc/nvidia-container-runtime/config.toml`
  (`mode = "auto"`), its `nvidia-cdi-refresh` units present but not enabled;
- **containerd** with the `nvidia` runtime handler (`BinaryName /usr/bin/nvidia-container-runtime`, `runc`
  stays the default) and CDI on (`enable_cdi`, spec dirs `/etc/cdi` and `/var/run/cdi`);
- Flatcar's legacy **`nvidia.service`** (`setup-nvidia`), which builds the driver for the running kernel at
  first boot — kept by Flatcar for backwards compatibility, used by the pool only with
  `pool.nvidiaDriver.source: image-build`.

The **NVIDIA driver** comes with the pool (`pool.nvidiaDriver`). By default (`source: flatcar-sysext`) it is
the prebuilt, release-matched `flatcar-nvidia-drivers-<branch>` system extension Flatcar ships next to every
image since 4344.0.0: the kernel modules for the release's kernel, `libcuda.so`, `libnvidia-ml.so` and friends
under `/usr/lib64`, `nvidia-smi` and the other driver binaries under `/usr/bin`. The bootstrap writes
`nvidia-drivers-<branch>` to `/etc/flatcar/enabled-sysext.conf`; at first boot, right after Ignition, the OS
downloads the extension image for its own version from Flatcar's release server (about 400 MB, verified with
the release key), keeps it under `/etc/flatcar/sysext/` and merges it into `/usr` before the system starts, so
the driver is in place when containerd and kubelet start and the node registers like any other node.
`nvidia.service` is masked. `update-engine` is masked on the nodes, so nothing updates the extension later; a
node is replaced, not updated.

The pool's bootstrap adds one unit, `nvidia-cdi-spec.service`, ordered after `systemd-sysext.service` and
`systemd-modules-load.service`: it loads the modules through the extension's modprobe helper
(`modprobe -a nvidia nvidia_uvm nvidia_modeset`), creates the device nodes (`nvidia-ctk system
create-device-nodes --control-devices`, then `nvidia-smi -L` for one node per GPU), sets the runtime to
`mode = "cdi"` and writes the CDI specification of the driver to `/var/run/cdi/nvidia.yaml`
(`nvidia-ctk cdi generate`). In `auto` mode the runtime would generate that specification per container,
locating the driver through containerd's PATH; with the specification written once, the runtime injects
exactly what it says. (With the driver built at boot, whose binaries land under `/opt/bin`, that
per-container discovery mounted `nvidia-smi` off every container's PATH and the GPU operator's toolkit
validation never passed — the reason the pool sets `mode = "cdi"` for both sources.)

`pool.nvidiaDriver.branch` picks the branch (`570` by default; `535` and `550` as Flatcar ships them) — the
CUDA runtime image decides which branches it accepts. `pool.nvidiaDriver.baseURL` names a directory holding
the release's `flatcar-nvidia-drivers-<branch>.raw` for a network the Flatcar release server is not reachable
from: Ignition downloads the image from there into `/etc/flatcar/sysext/flatcar-nvidia-drivers-<branch>-<flatcar>.raw`,
the path the OS looks at first, and the OS activates it without downloading. The download path and the guard
read the Flatcar version from `pool.machineImage`: an image older than 4344.0.0 has no extension on the
release server and the OS would fail the boot looking for it, so the chart refuses the render — as it refuses
an image whose name carries no Flatcar version. `source: image-build` is the choice for such an image and
renders the bootstrap without the extension: `nvidia.service` builds the driver at first boot (minutes per
node, with containerd and kubelet coming back after it) and the CDI unit waits for it.

The GPU operator runs on the `flatcar` row of cluster-manager's table: `driver.enabled=false`,
`toolkit.enabled=false`, operands under RuntimeClass `nvidia`, `cdi.enabled=true`. Its operands get every
GPU through the runtime (`NVIDIA_VISIBLE_DEVICES=all` → `nvidia.com/gpu=all` from the specification);
workloads requesting `nvidia.com/gpu` get theirs through the device plugin's CDI devices, which containerd
injects natively. A node is a GPU node once `nvidia.com/gpu` is allocatable and the ClusterPolicy is
`ready`; no step on the node is left to a person.

## Prewarming the first node

A pool scales from zero: its first node launches when the first workload goes Pending — after
the serving stack that loads a model is ready — and a fresh node needs minutes to become a GPU
node. With `pool.prewarm.enabled` the chart launches that node at install. A one-shot **Job**
`<cluster>-<pool>-prewarm` in the release's namespace runs a pod that requests one `nvidia.com/gpu`,
tolerates the pool's taint, selects the pool's nodes (`giantswarm.io/machine-pool`) and sleeps
`pool.prewarm.holdMinutes`, under the **PriorityClass** named by `pool.prewarm.priorityClassName`
— a class of negative value with `preemptionPolicy: Never`. Karpenter launches the node for the
placeholder; the first workload (priority 0) preempts the placeholder and takes its GPU.

The chart renders no PriorityClass. The class is cluster-scoped, and a pool release is delivered
as the organisation's tenant ServiceAccount, whose rights end at the release namespace — a
release rendering one fails to install. The default, `agent-platform-prewarm-placeholder`
(value -1000, `preemptionPolicy: Never`), is shipped by the agent-platform release with its
model-serving component; an empty name is refused at render, since a pod without a class has
priority 0 and no workload preempts it. Where the class does not exist on the cluster the pool
installs all the same: admission refuses the Job's pod (`no PriorityClass with name … was
found`), no node launches, the Job ends at its deadline and removes itself, and the first node
comes with the first workload as without prewarm.

The placeholder never launches a second node. The Job has `restartPolicy: Never` and
`backoffLimit: 0`, so a preempted pod is not replaced; its `activeDeadlineSeconds` — the hold
plus ten minutes for the node launch — ends a placeholder whose node never came; a finished Job
removes itself (`ttlSecondsAfterFinished`) and an empty node goes with `pool.consolidateAfter`.
The Job is rendered on install only (`.Release.IsInstall`): an upgrade never re-creates it, and
`helm.toolkit.fluxcd.io/driftDetection: disabled` keeps a Flux drift correction from bringing it
back. When no workload comes the prewarm costs one on-demand GPU instance for the hold.

The Job is created where the release lives, on the management cluster; the pool's nodes join
`cluster.name`. Both are one cluster only for the installation's own pool, so the chart refuses
`pool.prewarm.enabled` where `cluster.name` is not `cluster.managementCluster`.

## The lib volume

`/var/lib` (`/dev/xvdd`: container images and kubelet) is a gp3 volume whose provisioned
performance bounds the image pulls on a fresh node, and a serving runtime image is several
gigabytes. `pool.volumes.libThroughput` (MiB/s, default 500) and `pool.volumes.libIops` (default
4000) set the volume's `ebs.throughput` and `ebs.iops`. gp3 allows 125 to 1000 MiB/s and 3000
to 16000 IOPS with at most 0.25 MiB/s per provisioned IOPS; the chart refuses a pair beyond that
ratio, which EC2 would refuse at launch. The root and log volumes stay at gp3's baseline
(125 MiB/s, 3000 IOPS).

## Pinning the pool to zones

Karpenter launches a pool's node in any zone the cluster's node subnets span and the
instance family is offered in — right until something zonal enters. A PersistentVolume on
EBS lives in one zone, and a pod that mounts it schedules only there. An installation that
keeps a model cache claim is the case at hand: the predictor mounting the cache is pinned to
the claim's zone while the [prewarm](#prewarming-the-first-node) placeholder is not, so the
placeholder's node may launch in another zone; under a one-GPU limit no second node
follows, and the predictor sits Pending (`didn't match PersistentVolume's node affinity`)
on a pool that reads ready.

`pool.zones` (default empty: no constraint) adds a `topology.kubernetes.io/zone In [...]`
requirement to the NodePool template, so every node of the pool — placeholder and workload
alike — comes up in the named zones; Karpenter picks the subnet there. cluster-manager sets
it from the kept cache claim's zone where the installation has one. A zone outside the
cluster's node subnets launches nothing.

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
teleport, compares the goldens, validates every `KarpenterMachinePool` against the CRD served by
the pinned aws-resolver-rules-operator (fields, types, patterns and enums — not its CEL rules),
holds every object of a render to the release namespace (nothing cluster-scoped), renders the
prewarm Job into its own golden — under the default class and under a named one — renders the
`KarpenterMachinePool` of a zone-pinned pool into its own golden (the default goldens hold that
an empty `pool.zones` renders no zone requirement), renders the `KubeadmConfig` of
`pool.nvidiaDriver.source: image-build` and of a mirror (`pool.nvidiaDriver.baseURL`) into goldens of their
own (the default goldens hold the extension's bootstrap), checks the chart's refusals (prewarm off the
management cluster, an empty `pool.prewarm.priorityClassName`, a lib volume beyond gp3's
throughput-per-IOPS ratio, the extension on an image older than Flatcar 4344.0.0 or without a Flatcar
version in its name), and diffs the bootstrap — as the node sees it, files resolved —
against the newest released cluster-aws. Both
oracles are pinned in `hack/oracle/Chart.yaml` and bumped by Renovate. The intentional
differences are the one list in `hack/oracle/whitelist.yaml`; any other difference fails CI, so a
cluster-aws bump that changes the worker bootstrap fails until the chart follows. `make goldens`
rewrites the goldens.

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
| pool.zones | list | `[]` | Availability zones the pool's nodes launch in (`eu-central-1b`), among the cluster's node subnets; empty for any of them. An installation with a kept model cache pins its pools to the cache's zone: the claim is one EBS volume, and a node in another zone strands the workload mounting it. |
| pool.minSize | int | `0` | Minimum size; Karpenter scales the pool to zero when nothing is scheduled. |
| pool.maxSize | object | `{"nvidia.com/gpu":"4"}` | Upper bound of the pool, as Karpenter limits (resources across all of its nodes). |
| pool.consolidateAfter | string | `"10m"` | Time an empty or underutilized node lives before Karpenter consolidates it. |
| pool.volumes.root | string | `"15Gi"` | Root volume. |
| pool.volumes.lib | string | `"200Gi"` | `/var/lib` volume (container images, kubelet). |
| pool.volumes.libThroughput | int | `500` | Provisioned throughput of the `/var/lib` volume in MiB/s; image pulls on a fresh node are bounded by it. gp3 allows 125 to 1000 and at most 0.25 MiB/s per provisioned IOPS. |
| pool.volumes.libIops | int | `4000` | Provisioned IOPS of the `/var/lib` volume. gp3 allows 3000 to 16000. |
| pool.volumes.log | string | `"30Gi"` | `/var/log` volume. |
| pool.prewarm.enabled | bool | `false` | Launch the pool's first node at install: a one-shot Job holds one GPU at negative priority until the first workload preempts it. Only for the installation's own pool, where the release namespace is on the cluster the nodes join. |
| pool.prewarm.holdMinutes | int | `15` | Minutes the placeholder holds the node when no workload comes; then it ends and Karpenter consolidates the empty node. |
| pool.prewarm.image | string | `"gsoci.azurecr.io/giantswarm/alpine:3.22.1"` | Image of the placeholder; anything with `sleep`. |
| pool.prewarm.priorityClassName | string | `"agent-platform-prewarm-placeholder"` | Name of the PriorityClass the placeholder runs under: a negative value with `preemptionPolicy: Never`, so the first workload preempts it. The chart renders no PriorityClass (a pool release is namespaced); the agent-platform release ships this one. |
| pool.nvidiaDriver.source | string | `"flatcar-sysext"` | Where the node's NVIDIA driver comes from. `flatcar-sysext`: the prebuilt, release-matched `flatcar-nvidia-drivers-<branch>` system extension Flatcar ships next to the image (Flatcar 4344.0.0 and newer; an older image is refused), fetched and verified by the OS at first boot, so the node registers like any other node. `image-build`: Flatcar's `nvidia.service` builds the driver for the running kernel at each node's first boot, minutes per node. |
| pool.nvidiaDriver.branch | string | `"570"` | Driver branch of the extension (`535`, `550`, `570`), as Flatcar names it; the proprietary variant. |
| pool.nvidiaDriver.baseURL | string | `""` | Directory holding the release's `flatcar-nvidia-drivers-<branch>.raw` for a network the Flatcar release server is not reachable from: Ignition downloads the image from there at first boot and the OS activates it without downloading. Empty: the OS fetches it from Flatcar's release server for its own version. |
| teleport.enabled | bool | `true` | Join the nodes to Teleport with the cluster's `<cluster>-teleport-join-token` Secret; off where the cluster has none. |
