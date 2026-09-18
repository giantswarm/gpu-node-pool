# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `pool.prewarm` renders no PriorityClass (#15): a pool release is delivered as the organisation's tenant ServiceAccount, whose rights end at the release namespace, so the cluster-scoped class the chart rendered beside the placeholder Job failed the install (`InstallFailed`) and the pool never came up. The Job takes its class from `pool.prewarm.priorityClassName` (default `agent-platform-prewarm-placeholder`, shipped by the agent-platform release); an empty name is refused at render. `make verify` holds every object of a render to the release namespace.
- A pool node on the Giant Swarm Flatcar image reaches `nvidia.com/gpu` allocatable (#8): the bootstrap's `nvidia-cdi-spec.service`, ordered after Flatcar's `nvidia.service`, sets the image's NVIDIA container runtime to `mode = "cdi"` and writes the CDI specification of the driver to `/var/run/cdi/nvidia.yaml` with `/usr/bin` ahead of `/opt/bin` on its PATH. In `auto` mode the runtime located `nvidia-smi` through containerd's PATH (`/opt/bin` first on this image) and mounted it at `/opt/bin/nvidia-smi` in every container, off the PATH, so the GPU operator's toolkit validation looped on `nvidia-smi: executable file not found` and no GPU was ever advertised.
- The bootstrap diff against cluster-aws (`make verify`) whitelists single list elements (`files[path=…]`, `preKubeadmCommands[=…]`, `additionalConfig.systemd.units[name=…]`) and decodes the Ignition config, so an added unit no longer needs the whole `files` list or the whole Ignition config taken out of the comparison.

### Added

- `pool.zones` (#17): a list of availability zones adds a `topology.kubernetes.io/zone In [...]` requirement to the Karpenter NodePool template, so every node of the pool — prewarm placeholder and workload alike — comes up in the named zones; the default, an empty list, constrains nothing. A kept model cache claim is one EBS volume in one zone: a placeholder node launched in another zone stranded the predictor mounting the cache, Pending under a one-GPU limit on a pool that read ready.
- `pool.prewarm` (#12): when enabled, the chart launches the pool's first node at install — a one-shot Job `<cluster>-<pool>-prewarm` holds one `nvidia.com/gpu` of the pool at negative priority (`preemptionPolicy: Never`) until the first workload preempts it; `restartPolicy: Never` and `backoffLimit: 0` keep a preempted placeholder from launching a second node, `activeDeadlineSeconds` ends one whose node never came, and the Job is rendered on install only. Refused where `cluster.name` is not the management cluster, since the Job runs where the release lives.
- `pool.volumes.libThroughput` (MiB/s, default 500) and `pool.volumes.libIops` (default 4000) provision the lib volume's gp3 throughput and IOPS (#12); image pulls on a fresh node were bounded by the baseline 125 MiB/s. A pair beyond gp3's 0.25 MiB/s per IOPS is refused at render.
- `make verify` validates every rendered `KarpenterMachinePool` against the CRD served by the pinned aws-resolver-rules-operator chart (`hack/oracle/Chart.yaml`, bumped by Renovate) and checks the prewarm pair and the chart's refusals.
- The chart README states the image contract: what the Giant Swarm Flatcar image provides for GPUs (driver, container toolkit, containerd's `nvidia` runtime with CDI on) and what the pool configures.

[Unreleased]: https://github.com/giantswarm/gpu-node-pool/tree/main
